import Foundation

/// An immutable reply captured by the private CEF key-target channel. Only that channel can
/// issue it. The native agent owner parses and validates `replyJSON`, then redeems this same
/// snapshot before spending its person-key witness; a later page payload cannot replace it.
public nonisolated struct PageQuestionKeySnapshot: Sendable {
    public let target: PageQuestionKeyTarget
    public let replyJSON: String
    fileprivate let issuer: UUID
    fileprivate let ticket: UUID

    fileprivate init(target: PageQuestionKeyTarget, replyJSON: String, issuer: UUID, ticket: UUID) {
        self.target = target
        self.replyJSON = replyJSON
        self.issuer = issuer
        self.ticket = ticket
    }
}

/// One-use proofs of Return in the pending question's Other field. Uses the CEF host's existing
/// DevTools isolated-world primitives; no page-world callback or timestamp grants this proof.
@MainActor
final class ChromiumQuestionKeyChannel {
    private struct Issued {
        let snapshot: PageQuestionKeySnapshot
        let generation: Int
        let context: Int
        let nonce: String
        let sequence: Int
    }

    private weak var page: (any PageChromiumPage)?
    private let owns: (URL?) -> Bool
    private let world = "cmux-question-" + UUID().uuidString
    private let guardSecret = UUID().uuidString
    private(set) var documentGuardPrepared = false
    private var binding: String?
    private var generation = 0
    private var context: Int?
    private var nonce: String?
    private var sequence = 0
    private let issuer = UUID()
    /// At most one unused proof: the next genuine key replaces it.
    private var issued: Issued?
    private var targets: Set<PageQuestionKeyTarget> = []
    private var received: ((PageQuestionKeySnapshot) -> Void)?
    private var setup: Task<Void, Never>?
    /// Called when Chromium destroys the execution context behind the cached binding.
    /// The page owner clears its cache and asks for a fresh install.
    var onInvalidated: (@MainActor () -> Void)?

    init(page: any PageChromiumPage, owns: @escaping (URL?) -> Bool) {
        self.page = page
        self.owns = owns
    }

    /// Await this during page setup, before its first load. No `runImmediately`: a loaded page
    /// cannot prove our focus capture listener preceded its main-world listeners.
    func prepareDocumentGuard() async throws {
        guard !documentGuardPrepared, let page else { return }
        let result = try await page.devTools("Page.addScriptToEvaluateOnNewDocument", params: [
            "source": PageQuestionKeyScript.documentGuard(secret: guardSecret), "worldName": world,
        ])
        guard let identifier = ChromiumPageHostWire.object(result)?["identifier"] as? String, !identifier.isEmpty else {
            throw PageError.unavailable("question key focus guard was not registered")
        }
        documentGuardPrepared = true
    }

    /// The native owner must first invalidate its previous pending question/person-key witness.
    /// A callback proves only the DOM key target; the owner must also consume that native witness.
    func bind(_ target: PageQuestionKeyTarget, received: @escaping (PageQuestionKeySnapshot) -> Void) {
        bind([target], received: received)
    }

    func bind(_ targets: [PageQuestionKeyTarget], received: @escaping (PageQuestionKeySnapshot) -> Void) {
        let allowed = Set(targets)
        guard documentGuardPrepared, allowed.allSatisfy(\.isValid) else { invalidate(); return }
        if self.targets == allowed, nonce != nil {
            self.received = received
            return
        }
        invalidate()
        guard !allowed.isEmpty else { return }
        self.targets = allowed
        self.received = received
        let generation = generation
        let nonce = UUID().uuidString
        let binding = "__cmuxQuestionKey_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.binding = binding
        self.nonce = nonce
        setup = Task { [weak self] in await self?.install(Array(allowed), nonce: nonce, binding: binding, generation: generation) }
    }

    private func install(_ targets: [PageQuestionKeyTarget], nonce: String, binding: String, generation: Int) async {
        var installed = false
        defer {
            if self.generation == generation {
                setup = nil
                if !installed { invalidate() }
            }
        }
        guard let page else { return }
        do {
            let tree = try await page.devTools("Page.getFrameTree", params: [:])
            guard live(generation), let frame = Self.mainFrame(tree), owns(frame.url) else { return }
            let created = try await page.devTools("Page.createIsolatedWorld", params: ["frameId": frame.id, "worldName": world])
            guard live(generation), let context = ChromiumPageHostWire.object(created)?["executionContextId"] as? Int else { return }
            self.context = context
            // Bind to exactly this main-frame world, never all contexts or the page's main world.
            _ = try await page.devTools("Runtime.addBinding", params: ["name": binding, "executionContextId": context])
            guard live(generation), self.context == context else { return }
            // The frame may have navigated during setup. Check this context's origin and top frame
            // before putting the nonce in it; an old context fails rather than migrating to a new one.
            let sender = try await page.devTools("Runtime.evaluate", params: [
                "expression": "[location.href, window === window.top]", "contextId": context, "returnByValue": true, "silent": true,
            ])
            guard live(generation), let sender = ChromiumPageHostWire.Sender(evaluation: sender), sender.isTop, owns(sender.url) else { return }
            let result = try await page.devTools("Runtime.evaluate", params: [
                "expression": PageQuestionKeyScript.source(targets: targets, nonce: nonce, binding: binding,
                                                           generation: generation, guardSecret: guardSecret),
                "contextId": context, "returnByValue": true, "silent": true,
            ])
            installed = live(generation) && ChromiumPageHostWire.evaluationIsTrue(result)
        } catch {
            // A closed or navigating page grants nothing. The next native pending update can rebind.
            if live(generation) { invalidate() }
        }
    }

    private func live(_ generation: Int) -> Bool { self.generation == generation && !Task.isCancelled && nonce != nil }

    /// Runs before the ordinary page-world bridge sees events. A forged call in the main world,
    /// a stale context, the wrong secret, and every replay are all refused synchronously.
    @discardableResult
    func receive(_ json: String) -> Bool {
        guard let object = ChromiumPageHostWire.object(json), let method = object["method"] as? String else { return false }
        if method == "Runtime.executionContextsCleared" {
            invalidate()
            onInvalidated?()
            return false
        }
        if method == "Runtime.executionContextDestroyed",
           let params = object["params"] as? [String: Any], params["executionContextId"] as? Int == context {
            invalidate()
            onInvalidated?()
            return false
        }
        guard let call = ChromiumPageHostWire.BindingCall(event: json), call.name == binding else { return false }
        guard let nonce, let context, call.contextID == context,
              call.payload.utf8.count <= 2 * PageQuestionKeyScript.maximumReplyBytes + 2048,
              let report = ChromiumPageHostWire.object(call.payload),
              Set(report.keys) == ["nonce", "sequence", "sessionID", "permissionID", "replyJSON"],
              report["nonce"] as? String == nonce, let serial = report["sequence"] as? Int, serial > sequence,
              let sessionID = report["sessionID"] as? String, let permissionID = report["permissionID"] as? String,
              let received else { return true }
        // Spend this key before calling the owner. The listener stays while this question stays:
        // empty or incomplete answers must not spend the next genuine Return's proof.
        sequence = serial
        issued = nil
        let target = PageQuestionKeyTarget(sessionID: sessionID, permissionID: permissionID)
        guard targets.contains(target), let replyJSON = report["replyJSON"] as? String, Self.isReply(replyJSON) else { return true }
        let snapshot = PageQuestionKeySnapshot(target: target, replyJSON: replyJSON, issuer: issuer, ticket: UUID())
        issued = Issued(snapshot: snapshot, generation: generation, context: context, nonce: nonce, sequence: serial)
        received(snapshot)
        return true
    }

    /// Consumes this ticket before the suspension, then asks the original isolated context to
    /// revalidate its captured references and reply. The caller must recheck native pending
    /// state/decision nonce/person-instance and consume its person-key witness after this await.
    func redeem(_ snapshot: PageQuestionKeySnapshot) async -> Bool {
        guard snapshot.issuer == issuer, let issued, issued.snapshot.ticket == snapshot.ticket,
              issued.snapshot.target == snapshot.target, issued.snapshot.replyJSON == snapshot.replyJSON else { return false }
        self.issued = nil
        guard let page, let binding, current(issued) else { return false }
        let value = ChromiumPageHostWire.jsonString
        let expression = "globalThis[\(value(PageQuestionKeyScript.redemptionName(binding: binding)))]?.(\(value(issued.nonce)), \(issued.sequence), \(value(snapshot.replyJSON))) === true"
        guard let result = try? await page.devTools("Runtime.evaluate", params: [
            "expression": expression, "contextId": issued.context, "returnByValue": true, "silent": true,
        ]), current(issued) else { return false }
        return ChromiumPageHostWire.evaluationIsTrue(result)
    }

    private func current(_ issued: Issued) -> Bool {
        generation == issued.generation && context == issued.context && nonce == issued.nonce && sequence == issued.sequence
    }

    /// The transport checks the envelope only. Harness-specific answers and annotations remain
    /// the native question owner's policy, and the original string preserves absent vs `{}`.
    private static func isReply(_ json: String) -> Bool {
        guard json.utf8.count <= PageQuestionKeyScript.maximumReplyBytes, let reply = ChromiumPageHostWire.object(json),
              Set(reply.keys).isSubset(of: ["optionId", "answers", "annotations"]),
              let option = reply["optionId"] as? String, !option.isEmpty, reply["answers"] is [String: Any] else { return false }
        return reply["annotations"].map { $0 is [String: Any] } ?? true
    }

    /// Navigation, a pending-question change, session switch, close, or renderer death ends the
    /// proof before any async cleanup. There are no timers or polling loops.
    func invalidate() {
        generation += 1
        setup?.cancel()
        setup = nil
        nonce = nil
        sequence = 0
        issued = nil
        targets.removeAll()
        received = nil
        let binding = binding
        self.binding = nil
        guard let context, let page else { self.context = nil; return }
        self.context = nil
        // task-owner: best-effort removal from the old context; native proof was already revoked
        Task {
            _ = try? await page.devTools("Runtime.evaluate", params: [
                "expression": "globalThis.\(PageQuestionKeyScript.cleanup)?.(\(binding.map(ChromiumPageHostWire.jsonString) ?? "null"))",
                "contextId": context, "silent": true,
            ])
            if let binding { _ = try? await page.devTools("Runtime.removeBinding", params: ["name": binding]) }
        }
    }

    /// Whether this exact target collection is synchronized. An empty collection is synchronized
    /// when no listener exists; a failed non-empty install deliberately returns false so the owner
    /// can retry on its next refresh.
    func hasTargets(_ targets: [PageQuestionKeyTarget]) -> Bool {
        if targets.isEmpty { return self.targets.isEmpty && nonce == nil }
        return self.targets == Set(targets) && nonce != nil
    }

    private static func mainFrame(_ json: String) -> (id: String, url: URL?)? {
        guard let tree = ChromiumPageHostWire.object(json)?["frameTree"] as? [String: Any],
              let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return nil }
        return (id, (frame["url"] as? String).flatMap(URL.init(string:)))
    }
}
