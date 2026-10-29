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
/// method) is not retried until the next start.
@MainActor
final class ComputerUseConsentHost {
    private let consent: @Sendable () async -> Data?
    private let refused: @Sendable (String) async -> Void
    private var configuration: AgentActivitySocketSource.Configuration?
    private var connection: AgentActivityLineConnection?
    private var retry: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(250), maximum: .seconds(5))

    init(consent: @escaping @Sendable () async -> Data?, refused: @escaping @Sendable (String) async -> Void) {
        self.consent = consent
        self.refused = refused
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
        case question
        case other
    }

    nonisolated static func classify(_ object: [String: Any]) -> Line {
        switch object["type"] as? String {
        case "machine_consent", "consent_refused": .question
        case nil where object["ok"] as? Bool == true: .attached
        case nil: .refusedAttach
        default: .other
        }
    }

    private func open() {
        guard let configuration, connection == nil else { return }
        let connection = AgentActivityLineConnection(path: configuration.socketPath,
                                                     acceptsServer: CuaHelperIdentity.isHelperServer)
        self.connection = connection
        let consent = self.consent
        let refused = self.refused
        connection.start(send: Self.attachLine(configuration), onLine: { [weak self, weak connection] line in
            guard let connection,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            switch Self.classify(object) {
            case .question:
                _ = ComputerUseHelperV2Consent.handle(object, send: { connection.send($0) },
                                                      consent: consent, refused: refused)
            case .attached:
                // task-owner: one main-actor hop per attach; it only resets the retry spacing.
                Task { @MainActor in self?.backoff.reset() }
            case .refusedAttach:
                consentHostLogger.notice("cmux Computer Use helper does not take machine consent from this app: \(String(decoding: line.prefix(256), as: UTF8.self), privacy: .public)")
                connection.cancel()
            case .other:
                break
            }
        }, onClose: { [weak self, weak connection] in
            // task-owner: one main-actor hop per lost connection; it schedules at most one retry.
            Task { @MainActor in self?.lost(connection) }
        })
    }

    private func lost(_ lostConnection: AgentActivityLineConnection?) {
        guard let lostConnection, connection === lostConnection else { return }
        connection = nil
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
