// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Computer Use service as the helper and the cmux Remote worker run
/// it: upstream Cua Driver under the configured mode's ceiling, one
/// upstream session per admitted connection, app approvals and machine
/// consent through the host consent socket. Built once at launch, from the
/// environment the host set; nothing a socket request sends changes it.
public struct ComputerUseStack: Sendable {
    public let sessions: any AgentSessionProviding
    /// Machine-join consent, asked of the host.
    public let consent: HostConsentChannel
    /// App approvals, asked of the host (`ask` only).
    public let approvals: AppApprovalBroker?
    /// The mode and client this worker runs with (nil when the environment names no valid mode);
    /// `ready` reports them so the app sees the client its questions will carry.
    public let configuration: ComputerUseConfiguration?

    /// When the configuration is invalid or the driver does not load, every
    /// call fails with the reason (written to stderr), and nothing runs.
    public init(libraryPath: String, environment: [String: String], allowedTargetBundleIDs: String,
                hostBundleID: String?, log: (String) -> Void) {
        let consent = HostConsentChannel()
        self.consent = consent
        let parsed = Result { try ComputerUseConfiguration(environment: environment) }
        configuration = try? parsed.get()
        do {
            let configuration = try parsed.get()
            guard let manifests = ManifestStoreLocation.perProcess() else {
                throw ToolError("this user's temp directory is unavailable for Computer Use manifests")
            }
            let runtime = try CuaDriverRuntime(libraryPath: libraryPath, configuration: configuration,
                                               manifests: manifests)
            let broker = AppApprovalBroker(client: configuration.client, machine: configuration.machine)
            approvals = configuration.mode == .ask ? broker : nil
            sessions = ComputerUseSessions(driver: runtime, configuration: configuration, broker: broker,
                                           gate: ConsentGate(authority: consent), manifests: manifests,
                                           allowedTargetBundleIDs: allowedTargetBundleIDs,
                                           hostBundleID: hostBundleID)
        } catch {
            log(String(describing: error))
            approvals = nil
            sessions = SharedToolSessions(tools: UnavailableTools(reason: String(describing: error)))
        }
    }

    /// The control pipe on stdin and stdout, serving this stack.
    public func controller() -> HelperController {
        HelperController(sessions: sessions, consent: consent, approvals: approvals, configuration: configuration)
    }
}
