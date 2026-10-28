import Foundation

/// One-use proofs of Return in the pending question's Other field. Uses the CEF host's existing
/// DevTools isolated-world primitives; no page-world callback or timestamp grants this proof.
@MainActor
final class ChromiumQuestionKeyChannel {
    private weak var page: (any PageChromiumPage)?
    private let owns: (URL?) -> Bool
    private let world = "cmux-question-" + UUID().uuidString
    private var binding: String?
    private var generation = 0
    private var context: Int?
    private var nonce: String?
    private var sequence = 0
    private var target: PageQuestionKeyTarget?
    private var received: ((PageQuestionKeyTarget) -> Void)?
    private var setup: Task<Void, Never>?

    init(page: any PageChromiumPage, owns: @escaping (URL?) -> Bool) {
        self.page = page
        self.owns = owns
    }

    /// The native owner must first invalidate its previous pending question/person-key witness.
    /// A callback proves only the DOM key target; the owner must also consume that native witness.
    func bind(_ target: PageQuestionKeyTarget, received: @escaping (PageQuestionKeyTarget) -> Void) {
        invalidate()
        guard target.isValid else { return }
        self.target = target
        self.received = received
        let generation = generation
        let nonce = UUID().uuidString
        let binding = "__cmuxQuestionKey_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.binding = binding
        self.nonce = nonce
        setup = Task { [weak self] in await self?.install(target, nonce: nonce, binding: binding, generation: generation) }
    }

    private func install(_ target: PageQuestionKeyTarget, nonce: String, binding: String, generation: Int) async {
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
            _ = try await page.devTools("Runtime.evaluate", params: [
                "expression": PageQuestionKeyScript.source(target: target, nonce: nonce, binding: binding, generation: generation),
                "contextId": context, "silent": true,
            ])
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
            return false
        }
        if method == "Runtime.executionContextDestroyed",
           let params = object["params"] as? [String: Any], params["executionContextId"] as? Int == context {
            invalidate()
            return false
        }
        guard let call = ChromiumPageHostWire.BindingCall(event: json), call.name == binding else { return false }
        guard let nonce, call.contextID == context, call.payload.utf8.count < 256,
              let report = ChromiumPageHostWire.object(call.payload), Set(report.keys) == ["nonce", "sequence"],
              report["nonce"] as? String == nonce, report["sequence"] as? Int == sequence + 1,
              let target, let received else { return true }
        // Spend this key before calling the owner. The listener stays while this question stays:
        // empty or incomplete answers must not spend the next genuine Return's proof.
        sequence += 1
        received(target)
        return true
    }

    /// Navigation, a pending-question change, session switch, close, or renderer death ends the
    /// proof before any async cleanup. There are no timers or polling loops.
    func invalidate() {
        generation += 1
        setup?.cancel()
        setup = nil
        nonce = nil
        sequence = 0
        target = nil
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

    private static func mainFrame(_ json: String) -> (id: String, url: URL?)? {
        guard let tree = ChromiumPageHostWire.object(json)?["frameTree"] as? [String: Any],
              let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return nil }
        return (id, (frame["url"] as? String).flatMap(URL.init(string:)))
    }
}
