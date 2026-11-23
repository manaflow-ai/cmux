public import CmuxNextDaemon
import CmuxNextWakeups
import CryptoKit
public import Foundation
public import Observation

/// The Mac app's side of Chief hands (docs/chief-hands.md, bead cx-om025): what views observe,
/// fed by the hands engine (``HandsEngine``, cmux-tui `cmux cloud hands`), and the two keys
/// only this Mac has. The engine follows the user socket, reads the waiting requests, calls the
/// hand routes and builds each text this app signs; this service signs with the install key
/// (Allow, the presence key's registration) or the Secure Enclave presence key (a raise, after
/// Touch ID, Face ID or the login password; the prompt names the hand and the level).
/// ``onPending`` and ``onSettled`` post and withdraw the banners.
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

    @ObservationIgnored private let apiBaseURL: URL
    @ObservationIgnored private let accessToken: @Sendable () async throws -> String
    @ObservationIgnored private let identity: MacInstallIdentity
    @ObservationIgnored private let presence: HandPresenceKeyStore
    @ObservationIgnored private let engine: HandsEngine
    @ObservationIgnored private var started = false
    @ObservationIgnored private var relaunch = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
    @ObservationIgnored private var restart: Task<Void, Never>?
    private static let logLimit = 64

    /// - Parameter cli: The app's bundled `cmux`, which runs the hands engine.
    public init(apiBaseURL: URL, accessToken: @escaping @Sendable () async throws -> String, identity: MacInstallIdentity,
                presence: HandPresenceKeyStore, cli: BundledExecutable) {
        (self.apiBaseURL, self.accessToken, self.identity, self.presence) = (apiBaseURL, accessToken, identity, presence)
        engine = HandsEngine(cli: cli)
        engine.onEvent = { [weak self] event, object in self?.handle(event, object) }
        engine.onExit = { [weak self] in self?.engineExited() }
    }

    /// Signed in: follow the user socket; each subscribe reads the hands and their waiting requests.
    public func start() {
        started = true
        // A fresh sign-in owes nothing to an earlier session's crashes.
        relaunch.reset()
        engine.send(startCommand)
    }

    /// Signed out: stop following and withdraw every banner.
    public func stop() {
        started = false
        restart?.cancel()
        engine.send(["t": "stop"])
        prompt?.cancel()
        drop()
    }

    private var startCommand: [String: Any] {
        var command: [String: Any] = ["t": "start", "api": apiBaseURL.absoluteString]
        // updates.minimumVersion: an owner refuses a client that does not name its version.
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { command["app_version"] = version }
        return command
    }

    private func drop() {
        let dropped = pending.values
        (pending, hands) = ([:], [])
        for approval in dropped { onSettled?(approval, nil) }
    }

    private func engineExited() {
        drop()
        guard started else { return }
        note("hands engine ended")
        let delay = relaunch.next()
        restart?.cancel()
        // task-owner: HandsService.engineExited: one relaunch per engine exit, after a growing delay; stop() cancels it.
        restart = Task { [weak self] in
            // wakeup-allow: one-shot relaunch delay after the engine exited.
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.started else { return }
            self.engine.send(self.startCommand)
        }
    }

    private func handle(_ event: String, _ object: [String: Any]) {
        func decode<T: Decodable>(_ value: Any?, as: T.Type) -> T? {
            value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        switch event {
        case "token":
            guard let id = (object["id"] as? NSNumber)?.uint64Value else { return }
            // task-owner: HandsService.handle: one token answer per engine ask; it ends when the session answers.
            Task { [weak self, accessToken] in
                // A signed-out session (it throws) answers null: the engine reads nothing.
                let credential: Any = (try? await accessToken()).map { $0 as Any } ?? NSNull()
                self?.engine.send(["t": "token", "id": id, "credential": credential])
            }
        case "hands":
            // Any list the engine read, an empty one too, means it runs: the next exit waits the least again.
            let listed = decode(object["hands"], as: [HandSummary].self)
            hands = listed ?? []
            if listed != nil { relaunch.reset() }
        case "pending":
            guard let approval = decode(object["approval"], as: HandApproval.self), pending[approval.key] == nil else { return }
            pending[approval.key] = approval
            onPending?(approval, object["name"] as? String ?? approval.hand)
        case "settled":
            guard let approval = decode(object["approval"], as: HandApproval.self), let shown = pending.removeValue(forKey: approval.key) else { return }
            onSettled?(shown, (object["outcome"] as? String).flatMap(HandApprovalOutcome.init(rawValue:)))
        case "log":
            if let line = object["line"] as? String { note(line) }
        default:
            break
        }
    }

    private func name(of hand: String) -> String {
        hands.first { $0.hand == hand }.map { $0.name.isEmpty ? hand : $0.name } ?? hand
    }

    /// Reads the hands and the waiting requests of each hand that has any.
    public func refresh() async {
        _ = try? await engine.call("refresh", as: Empty.self)
    }

    // MARK: - Answers

    /// Allow or Deny one waiting request. An answer the server already has ends the banner too.
    public func answer(_ key: String, allow: Bool) async throws {
        guard let approval = pending[key] else { throw Failure.unknownApproval(key) }
        do {
            if allow {
                let context = try await proofContext()
                let text = try await call("allow_text", ["key": key, "environment": context.environment], as: Text.self).text
                let signature = try await identity.signWithInstallKey(text)
                _ = try await call("answer", ["key": key, "allow": true, "install": context.install, "signature": signature], as: Empty.self)
            } else {
                _ = try await call("answer", ["key": key, "allow": false], as: Empty.self)
            }
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
    }

    // MARK: - Levels

    /// Makes this install's presence key once and registers it for the install (the install key
    /// signs the registration). Answers the install id.
    @discardableResult
    public func enrollPresence() async throws -> String {
        let context = try await proofContext()
        var record = try presence.recordOrCreate(for: context.user)
        if record.install == context.install { return context.install }
        let text = try await call("presence_text", ["environment": context.environment, "install": context.install, "x": record.x, "y": record.y],
                                  as: Text.self).text
        let signature = try await identity.signWithInstallKey(text)
        _ = try await call("register_presence_key", ["install": context.install, "x": record.x, "y": record.y, "signature": signature], as: Empty.self)
        record.install = context.install
        try presence.save(record, for: context.user)
        note("presence key registered for \(context.install)")
        return context.install
    }

    /// Sets `hand`'s level: a lower at once, a raise with the presence proof.
    public func setLevel(hand id: String, to level: HandLevel) async throws {
        guard let hand = hands.first(where: { $0.hand == id }) else { throw Failure.unknownHand(id) }
        var request: [String: Any] = ["target": id, "level": level.rawValue]
        if let known = hand.level { request["known"] = known.rawValue }
        if try await call("set_level", request, as: LevelAnswer.self).needsProof == true {
            try await raise(target: id, to: level, reason: texts.raiseHand(hand.name.isEmpty ? id : hand.name, level.rawValue))
        }
        note("level \(id) \(hand.level?.rawValue ?? "?") -> \(level.rawValue)")
        if let now = hands.firstIndex(where: { $0.hand == id }) { hands[now].level = level }
    }

    /// Sets the owner default for new `profile` hands. The app does not know the current default,
    /// so the plain `PUT` goes first; the server refuses a raise, which then takes the proof.
    public func setDefault(profile: HandProfile, to level: HandLevel) async throws {
        let target = "default:\(profile.rawValue)"
        if try await call("set_level", ["target": target, "level": level.rawValue], as: LevelAnswer.self).needsProof == true {
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
        let challenge = try await call("challenge", ["target": target, "level": level.rawValue, "environment": context.environment], as: Challenge.self)
        let prompt = HandPresencePrompt(reason: reason)
        self.prompt = prompt
        note("presence prompt requested: \(reason)")
        defer { if self.prompt === prompt { self.prompt = nil } }
        let signature = try await HandPresenceKey.sign(challenge.text, blob: record.blob, reason: reason, prompt: prompt)
        try await setLevel(target: target, level: level, proof: (context.install, challenge.nonce, signature))
    }

    /// Proof only (`debug.hands`): a raise whose challenge is signed by the install key, not the
    /// presence key. The server must refuse it (`hand.level_refused`).
    public func raiseWithoutPresence(hand id: String, to level: HandLevel) async throws {
        let context = try await proofContext()
        let challenge = try await call("challenge", ["target": id, "level": level.rawValue, "environment": context.environment], as: Challenge.self)
        let signature = try await identity.signWithInstallKey(challenge.text)
        try await setLevel(target: id, level: level, proof: (context.install, challenge.nonce, signature))
    }

    private func setLevel(target: String, level: HandLevel, proof: (install: String, nonce: String, signature: String)) async throws {
        _ = try await call("set_level", ["target": target, "level": level.rawValue,
                                         "proof": ["install": proof.install, "nonce": proof.nonce, "signature": proof.signature]], as: LevelAnswer.self)
    }

    /// The install proof context; a Mac with no registered Cloud install throws ``Failure/notLinked(_:)``.
    private func proofContext() async throws -> (user: String, install: String, environment: String) {
        do { return try await identity.proofContext() } catch MacInstallIdentity.Failure.signedOut { throw Failure.notLinked(texts.notLinked) }
    }

    // MARK: - Engine calls

    private struct Empty: Decodable {}
    private struct Text: Decodable { var text: String }
    private struct Challenge: Decodable { var nonce: String, text: String }
    private struct LevelAnswer: Decodable {
        var needsProof: Bool?
        enum CodingKeys: String, CodingKey { case needsProof = "needs_proof" }
    }

    /// One engine call; its refusal reads as the ``CloudAPIError`` (or ``Failure``) it stands for.
    private func call<Reply: Decodable>(_ op: String, _ params: [String: Any] = [:], as: Reply.Type) async throws -> Reply {
        do {
            return try await engine.call(op, params, as: Reply.self)
        } catch let refusal as HandsEngine.Refusal {
            switch refusal.kind {
            case "not_signed_in": throw CloudAPIError.notSignedIn
            case "timed_out": throw CloudAPIError.timedOut(refusal.message)
            case "http": throw CloudAPIError.http(status: refusal.status ?? 0, code: refusal.code, message: refusal.message.isEmpty ? nil : refusal.message)
            case "decoding": throw CloudAPIError.decoding(refusal.message)
            case "unknown_approval": throw Failure.unknownApproval(refusal.message)
            default: throw CloudAPIError.transport(refusal.message)
            }
        }
    }

    func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    // MARK: - debug.hands

    /// `debug.hands` (the App's control socket, debug builds and proofs): the service's state as JSON
    /// text, after one optional action.
    ///
    /// - `{"action": "refresh"}` reads the hands and their waiting requests.
    /// - `{"action": "enroll"}` makes and registers the presence key.
    /// - `{"action": "level", "hand": <id>, "level": <level>}` and
    ///   `{"action": "default", "profile": <profile>, "level": <level>}` start a level change and answer
    ///   at once (a raise waits for the presence prompt; `prompt` shows its reason, `log` the result).
    /// - `{"action": "cancel_prompt"}` cancels the presence prompt that asks now.
    /// - `{"action": "raise_unsigned", "hand": <id>, "level": <level>}` sends a raise signed by the
    ///   install key, not the presence key; `result` is the server's answer (it must refuse).
    ///
    /// Waiting requests are answered through `debug.notifications` (`allow`/`deny` with the banner id),
    /// the banner's own path.
    public func debug(_ params: [String: String]) async -> String {
        var result: String?
        let level = params["level"].flatMap(HandLevel.init(rawValue:))
        switch params["action"] {
        case "refresh":
            await refresh()
        case "enroll":
            result = await Self.outcome { _ = try await self.enrollPresence() }
        case "level":
            if let hand = params["hand"], let level { begin("level \(hand) \(level.rawValue)") { try await self.setLevel(hand: hand, to: level) } }
        case "default":
            if let profile = params["profile"].flatMap(HandProfile.init(rawValue:)), let level {
                begin("default \(profile.rawValue) \(level.rawValue)") { try await self.setDefault(profile: profile, to: level) }
            }
        case "cancel_prompt":
            prompt?.cancel()
        case "raise_unsigned":
            if let hand = params["hand"], let level { result = await Self.outcome { try await self.raiseWithoutPresence(hand: hand, to: level) } }
        default:
            break
        }
        let state: [String: Any] = ["prompt": prompt.map { $0.reason as Any } ?? NSNull(), "secure_enclave": SecureEnclave.isAvailable,
                                    "result": result.map { $0 as Any } ?? NSNull(), "log": log]
        return (try? await engine.call("report", state, as: Text.self).text) ?? #"{"error":"the hands engine is not running"}"#
    }

    /// Runs `work` without waiting for it; the log records how it ended.
    private func begin(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        // task-owner: HandsService.debug: one proof-driven level change; it ends with its prompt or request.
        Task { @MainActor [weak self] in
            let ended = await Self.outcome { try await work() }
            self?.note("\(label): \(ended)")
        }
    }

    private static func outcome(_ work: @MainActor () async throws -> Void) async -> String {
        do {
            try await work()
            return "ok"
        } catch CloudAPIError.http(let status, let code, let message, _, _) {
            return "refused \(status) \(code ?? "") \(message ?? "")"
        } catch {
            return "failed \(error)"
        }
    }
}
