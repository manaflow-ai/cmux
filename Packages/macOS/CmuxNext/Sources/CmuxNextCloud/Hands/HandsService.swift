public import Foundation
public import Observation

/// The Mac app's side of Chief hands (docs/chief-hands.md, bead cx-om025): the owner's hands and
/// their levels, the presence key that raises a level, and the requests that wait for the owner.
///
/// - A lower is a plain `PUT {level}`. A raise takes a single-use challenge, a presence-key
///   signature (Touch ID, Face ID or the login password; the prompt names the hand and the level)
///   and then the `PUT`. A Mac without a Secure Enclave refuses raises (``HandPresenceError/unavailable``).
/// - Waiting requests come from the user socket (``HandApprovalWire``) and from the list read after
///   each subscribe. ``onPending`` and ``onSettled`` post and withdraw their banners. Deny needs only
///   the session; Allow adds the install key's signature over the approval text, which the app
///   builds from ids it checked (it never signs a text that the server or the wire sent).
@MainActor
@Observable
public final class HandsService {
    public enum Failure: Error, Equatable, LocalizedError {
        case unknownHand(String)
        case unknownApproval(String)
        /// This Mac has no registered Cloud install (signed out, or Cloud is off here): nothing can
        /// sign an allow or a raise. The text is the localized `texts.notLinked`.
        case notLinked(String)

        public var errorDescription: String? {
            if case let .notLinked(text) = self { return text }
            return nil
        }
    }

    public private(set) var hands: [HandSummary] = []
    /// The waiting requests, by ``HandApproval/key``.
    public private(set) var pending: [String: HandApproval] = [:]
    /// The presence prompt that asks now, else nil.
    public private(set) var prompt: HandPresencePrompt?
    /// What happened, newest last (bounded; for `debug.hands`).
    public private(set) var log: [String] = []
    /// A request now waits: post its banner (the hand's name for the title).
    /// Set after ``start()`` ran, it posts the requests that already wait.
    @ObservationIgnored public var onPending: (@MainActor (HandApproval, _ handName: String) -> Void)? {
        didSet { for approval in pending.values.sorted(by: { $0.at < $1.at }) { onPending?(approval, name(of: approval.hand)) } }
    }
    /// A request ended (nil outcome: the app stopped following it): withdraw its banner.
    @ObservationIgnored public var onSettled: (@MainActor (HandApproval, HandApprovalOutcome?) -> Void)?
    /// The presence prompt's reasons (raising hand `name` to `level`; raising the default of new
    /// `profile` hands; raw level and profile values) and why a Mac without a Secure Enclave, or with no
    /// registered Cloud install, refuses raises and allows. The App sets CmuxNextAgentPane's localized `AgentApprovalBanners.handTexts`.
    @ObservationIgnored public var texts: (raiseHand: (_ name: String, _ level: String) -> String, raiseDefault: (_ profile: String, _ level: String) -> String,
                                             unavailable: String, notLinked: String) =
        ({ "raise the hand \($0) to \($1)" }, { "raise the default level of new \($0) hands to \($1)" }, "This Mac has no Secure Enclave.",
         "This Mac is not set up for Cloud.")

    @ObservationIgnored private let api: HandsAPIClient
    @ObservationIgnored private let identity: MacInstallIdentity
    @ObservationIgnored private let presence: HandPresenceKeyStore
    @ObservationIgnored private let wire: HandApprovalWire
    @ObservationIgnored private var reads: Task<Void, Never>?
    /// When each waiting request arrived here, so a list read that started earlier never drops it.
    @ObservationIgnored private var arrived: [String: ContinuousClock.Instant] = [:]
    /// When each request ended here, so a list read that started earlier never posts it again.
    @ObservationIgnored private var ended: [String: ContinuousClock.Instant] = [:]
    private static let logLimit = 64

    public init(apiBaseURL: URL, accessToken: @escaping HandsAPIClient.AccessToken, identity: MacInstallIdentity,
                presence: HandPresenceKeyStore) {
        api = HandsAPIClient(baseURL: apiBaseURL, accessToken: accessToken)
        wire = HandApprovalWire(apiBaseURL: apiBaseURL, token: accessToken)
        (self.identity, self.presence) = (identity, presence)
    }

    /// Signed in: follow the user socket; each subscribe reads the hands and their waiting requests.
    public func start() {
        wire.start { [weak self] event in self?.handle(event) }
    }

    /// Signed out: stop following and withdraw every banner.
    public func stop() {
        wire.stop()
        reads?.cancel()
        reads = nil
        prompt?.cancel()
        let dropped = pending.values
        (pending, arrived, hands) = ([:], [:], [])
        for approval in dropped { onSettled?(approval, nil) }
    }

    private func handle(_ event: HandApprovalWire.Event) {
        switch event {
        case .connected:
            reads?.cancel()
            reads = Task { [weak self] in await self?.refresh() }
        case let .pending(approval):
            add(approval)
        case let .settled(hand, id, outcome):
            remove(HandApproval(hand: hand, id: id, summary: "", at: Date()).key, outcome: outcome)
        }
    }

    /// Reads the hands and the waiting requests of each hand that has any. A request the read no
    /// longer lists, and that arrived before the read began, ended while the socket was away.
    public func refresh() async {
        let began = ContinuousClock.now
        do {
            let listed = try await api.hands()
            try Task.checkCancellation()
            hands = listed
            var seen: Set<String> = []
            for hand in listed where (hand.pendingApprovals ?? 1) > 0 {
                let waiting = try await api.approvals(hand: hand.hand)
                try Task.checkCancellation()
                for approval in waiting where ended[approval.key] == nil {
                    seen.insert(approval.key)
                    add(approval)
                }
            }
            for key in pending.keys where !seen.contains(key) && (arrived[key] ?? began) < began {
                remove(key, outcome: nil)
            }
            ended = ended.filter { $0.value.duration(to: .now) < .seconds(600) }
            note("refreshed \(listed.count) hands, \(pending.count) waiting")
        } catch is CancellationError {
        } catch {
            note("refresh failed: \(error)")
        }
    }

    private func add(_ approval: HandApproval) {
        guard pending[approval.key] == nil else { return }
        pending[approval.key] = approval
        arrived[approval.key] = .now
        note("pending \(approval.key)")
        onPending?(approval, name(of: approval.hand))
    }

    private func name(of hand: String) -> String {
        hands.first { $0.hand == hand }.map { $0.name.isEmpty ? hand : $0.name } ?? hand
    }

    private func remove(_ key: String, outcome: HandApprovalOutcome?) {
        arrived[key] = nil
        ended[key] = .now
        guard let approval = pending.removeValue(forKey: key) else { return }
        note("settled \(key) \(outcome?.rawValue ?? "dropped")")
        onSettled?(approval, outcome)
    }

    // MARK: - Answers

    /// Allow or Deny one waiting request. An answer the server already has ends the banner too.
    public func answer(_ key: String, allow: Bool) async throws {
        guard let approval = pending[key] else { throw Failure.unknownApproval(key) }
        do {
            if allow {
                let context = try await proofContext()
                let text = HandProofText.approval(environment: context.environment, hand: approval.hand, id: approval.id)
                let signature = try await identity.signWithInstallKey(text)
                try await api.answer(hand: approval.hand, id: approval.id, allow: true, install: context.install, signature: signature)
            } else {
                try await api.answer(hand: approval.hand, id: approval.id, allow: false)
            }
        } catch CloudAPIError.http(_, let code, _, _, _) where ["hand.approval_answered", "hand.approval_not_found", "hand.not_found"].contains(code ?? "") {
            note("answer \(key): \(code ?? "") already")
            return remove(key, outcome: nil)
        } catch Failure.notLinked(let text) {
            // The banner comes back with the reason first, so the person sees why Allow did nothing.
            note("answer \(key) refused: \(text)")
            var shown = approval
            shown.summary = "\(text)\n\(approval.summary)"
            if pending[key] != nil { onPending?(shown, name(of: approval.hand)) }
            throw Failure.notLinked(text)
        } catch {
            // The system removed the banner when it was clicked: post it again, so the answer can be retried.
            note("answer \(key) failed: \(error)")
            if pending[key] != nil { onPending?(approval, name(of: approval.hand)) }
            throw error
        }
        note("answered \(key) \(allow ? "allow" : "deny")")
        remove(key, outcome: allow ? .allowed : .denied)
    }

    // MARK: - Levels

    /// Makes this install's presence key once and registers it for the install (the install key
    /// signs the registration). Answers the install id.
    @discardableResult
    public func enrollPresence() async throws -> String {
        let context = try await proofContext()
        var record = try presence.recordOrCreate(for: context.user)
        if record.install == context.install { return context.install }
        let text = HandProofText.presenceRegistration(environment: context.environment, install: context.install, x: record.x, y: record.y)
        let signature = try await identity.signWithInstallKey(text)
        try await api.registerPresenceKey(install: context.install, jwk: ["kty": "EC", "crv": "P-256", "x": record.x, "y": record.y],
                                          signature: signature)
        record.install = context.install
        try presence.save(record, for: context.user)
        note("presence key registered for \(context.install)")
        return context.install
    }

    /// Sets `hand`'s level: a lower at once, a raise with the presence proof.
    public func setLevel(hand id: String, to level: HandLevel) async throws {
        guard let index = hands.firstIndex(where: { $0.hand == id }) else { throw Failure.unknownHand(id) }
        let hand = hands[index]
        if let from = hand.level, !from.isRaise(to: level) {
            do {
                try await api.setLevel(target: id, level: level, proof: nil)
            } catch CloudAPIError.http(_, let code, _, _, _) where code == "hand.level_refused" {
                // The known level was stale (a Chief lowered it): this is a raise after all.
                try await raise(target: id, to: level, reason: texts.raiseHand(hand.name.isEmpty ? id : hand.name, level.rawValue))
            }
        } else {
            try await raise(target: id, to: level, reason: texts.raiseHand(hand.name.isEmpty ? id : hand.name, level.rawValue))
        }
        note("level \(id) \(hand.level?.rawValue ?? "?") -> \(level.rawValue)")
        if let now = hands.firstIndex(where: { $0.hand == id }) { hands[now].level = level }
    }

    /// Sets the owner default for new `profile` hands. The app does not know the current default,
    /// so it sends the plain `PUT` first; the server refuses a raise, which then takes the proof.
    public func setDefault(profile: HandProfile, to level: HandLevel) async throws {
        let target = "default:\(profile.rawValue)"
        do {
            try await api.setLevel(target: target, level: level, proof: nil)
        } catch CloudAPIError.http(_, let code, _, _, _) where code == "hand.level_refused" {
            try await raise(target: target, to: level, reason: texts.raiseDefault(profile.rawValue, level.rawValue))
        }
        note("default \(profile.rawValue) -> \(level.rawValue)")
    }

    private func raise(target: String, to level: HandLevel, reason: String) async throws {
        let install: String
        do { install = try await enrollPresence() } catch HandPresenceError.unavailable {
            note("raise refused: \(texts.unavailable)")
            throw HandPresenceError.unavailable
        } catch Failure.notLinked(let text) {
            note("raise refused: \(text)")
            throw Failure.notLinked(text)
        }
        let context = try await proofContext()
        guard install == context.install, let record = presence.record(for: context.user) else { throw HandPresenceError.unavailable }
        let nonce = try await api.challenge(target: target)
        let prompt = HandPresencePrompt(reason: reason)
        self.prompt = prompt
        note("presence prompt requested: \(reason)")
        defer { if self.prompt === prompt { self.prompt = nil } }
        let text = HandProofText.level(environment: context.environment, target: target, level: level, nonce: nonce)
        let signature = try await HandPresenceKey.sign(text, blob: record.blob, reason: reason, prompt: prompt)
        try await api.setLevel(target: target, level: level, proof: (context.install, nonce, signature))
    }

    /// Proof only (`debug.hands`): a raise whose challenge is signed by the install key, not the
    /// presence key. The server must refuse it (`hand.level_refused`).
    public func raiseWithoutPresence(hand id: String, to level: HandLevel) async throws {
        let context = try await proofContext()
        let nonce = try await api.challenge(target: id)
        let text = HandProofText.level(environment: context.environment, target: id, level: level, nonce: nonce)
        let signature = try await identity.signWithInstallKey(text)
        try await api.setLevel(target: id, level: level, proof: (context.install, nonce, signature))
    }

    /// The install proof context; a Mac with no registered Cloud install throws ``Failure/notLinked(_:)``.
    private func proofContext() async throws -> (user: String, install: String, environment: String) {
        do { return try await identity.proofContext() } catch MacInstallIdentity.Failure.signedOut { throw Failure.notLinked(texts.notLinked) }
    }

    func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
