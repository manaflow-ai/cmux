public import CmuxNextAgentActivity
import CmuxNextWakeups
import Foundation
import os

nonisolated private let consentHostLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Serves machine-join consent to the legacy cmux Computer Use helper.
///
/// The helper's build inside cmux.app (cmux-cua's `cmux-host-consent`)
/// trusts no file or environment variable for consent: it asks this app.
/// While the helper runs, this holds one `machine_consent_host` connection
/// to its socket (the helper checks the host token and this app's code
/// signature) and answers each `{"type":"machine_consent","id":N}` from
/// this app's own acpmux daemon (`AcpmuxMachineConsent`, through
/// `ComputerUseHelperV2Consent`). Without this connection the helper
/// refuses every call that needs consent.
///
/// Stop condition: `stop()` (the helper stops or exits) cancels the
/// connection and any retry. A lost connection is retried with `Backoff`
/// while the helper runs; a refused attach (an older helper without the
/// method, or `host_unverified`: this app build is not team-signed, so the
/// helper cannot verify it) is not retried until the next start.
@MainActor
final class ComputerUseConsentHost {
    private let consent: @Sendable () async -> Data?
    private let refused: @Sendable (String) async -> Void
    /// The helper refused this app as its host (`host_unverified`), with its
    /// reason; nil when a later connection is accepted, so a stale refusal clears.
    private let unverified: @MainActor (String?) -> Void
    private let acceptsServer: (@Sendable (UnixSocketPeer) -> Bool)?
    private var configuration: AgentActivitySocketSource.Configuration?
    private var connection: AgentActivityLineConnection?
    /// The connection whose questions are answered; read off the main actor
    /// by its line callback, so a stopped or replaced connection's late
    /// lines start no daemon query.
    private let current = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    private var retry: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(5))

    init(consent: @escaping @Sendable () async -> Data?, refused: @escaping @Sendable (String) async -> Void,
         unverified: @escaping @MainActor (String?) -> Void = { _ in },
         acceptsServer: (@Sendable (UnixSocketPeer) -> Bool)? = CuaHelperIdentity.isHelperServer) {
        self.consent = consent
        self.refused = refused
        self.unverified = unverified
        self.acceptsServer = acceptsServer
    }

    func start(_ configuration: AgentActivitySocketSource.Configuration) {
        stop()
        self.configuration = configuration
        open()
    }

    func stop() {
        configuration = nil
        retry?.cancel()
        retry = nil
        connection?.cancel()
        connection = nil
        current.withLock { $0 = nil }
        backoff.reset()
    }

    /// The first line on the connection: an authenticated host request.
    static func attachLine(_ configuration: AgentActivitySocketSource.Configuration) -> Data {
        let request: [String: Any] = ["method": "machine_consent_host", "args": [String: Any]()]
        var envelope: [String: Any] = ["auth_token": configuration.authToken ?? "", "request": request]
        if let host = configuration.hostAuthToken { envelope["host_auth_token"] = host }
        var data = (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// What one line from the helper asks of the host.
    nonisolated enum Line: Equatable {
        case attached
        case refusedAttach
        /// The helper cannot verify this app's code signature (an ad hoc
        /// signed dev build); the value is the helper's reason.
        case hostUnverified(String)
        case question
        case other
    }

    nonisolated static func classify(_ object: [String: Any]) -> Line {
        switch object["type"] as? String {
        case "machine_consent", "consent_refused": .question
        case nil where object["ok"] as? Bool == true
            && (object["result"] as? [String: Any])?["attached"] as? Bool == true: .attached
        case nil: hostUnverifiedReason(object["error"] as? String).map(Line.hostUnverified) ?? .refusedAttach
        default: .other
        }
    }

    /// The reason in `"...: host_unverified (<why>)"`, "" without one; nil
    /// for any other refusal (a host-token failure names no host_unverified).
    nonisolated static func hostUnverifiedReason(_ error: String?) -> String? {
        guard let error, let marker = error.range(of: "host_unverified") else { return nil }
        let rest = error[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("("), let close = rest.lastIndex(of: ")") else { return "" }
        return String(rest[rest.index(after: rest.startIndex)..<close])
    }

    private func open() {
        guard let configuration, connection == nil else { return }
        let connection = AgentActivityLineConnection(path: configuration.socketPath,
                                                     acceptsServer: acceptsServer)
        self.connection = connection
        let id = ObjectIdentifier(connection)
        current.withLock { $0 = id }
        let current = self.current
        let consent = self.consent
        let refused = self.refused
        connection.start(send: Self.attachLine(configuration), onLine: { [weak self, weak connection] line in
            guard let connection, current.withLock({ $0 == id }),
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            switch Self.classify(object) {
            case .question:
                _ = ComputerUseHelperV2Consent.handle(object, send: { connection.send($0) },
                                                      consent: consent, refused: refused)
            case .attached:
                // task-owner: one main-actor hop per attach; it resets the retry spacing and
                // clears an earlier host_unverified.
                Task { @MainActor in self?.accepted(connection: id) }
            case .refusedAttach:
                consentHostLogger.notice("cmux Computer Use helper does not take machine consent from this app: \(String(decoding: line.prefix(256), as: UTF8.self), privacy: .public)")
                connection.cancel()
            case .hostUnverified(let why):
                consentHostLogger.error("cmux Computer Use helper refused this app as its consent host: \(why, privacy: .public). Legacy Computer Use stays off in this build; use driver: upstream or a signed cmux build.")
                connection.cancel()
                // task-owner: one main-actor hop per refused attach; it only records the reason.
                Task { @MainActor in self?.refusedAsUnverified(why, connection: id) }
            case .other:
                break
            }
        }, onClose: { [weak self, weak connection] in
            // task-owner: one main-actor hop per lost connection; it schedules at most one retry.
            Task { @MainActor in self?.lost(connection) }
        })
    }

    private func accepted(connection id: ObjectIdentifier) {
        guard current.withLock({ $0 == id }) else { return }
        backoff.reset()
        unverified(nil)
    }

    private func refusedAsUnverified(_ why: String, connection id: ObjectIdentifier) {
        // A stopped or replaced connection's refusal says nothing about the current helper.
        guard current.withLock({ $0 == id }) else { return }
        unverified(why)
    }

    private func lost(_ lostConnection: AgentActivityLineConnection?) {
        guard let lostConnection, connection === lostConnection else { return }
        connection = nil
        current.withLock { $0 = nil }
        guard configuration != nil else { return }
        retry?.cancel()
        retry = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "computer-use.consent-host") } catch { return }
            self?.backoff = backoff
            self?.open()
        }
    }
}
