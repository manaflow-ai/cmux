import CmuxNextCloud
import CmuxNextCompat
import Foundation
import os

/// Sends each Cloud machine's chats their model credentials again on every new link to it (cmux#57418):
/// a VM that paused and resumed, or a daemon an update, a crash or a rollback restarted. The machine's
/// acpmux keeps a chat's launch credential (a Claude setup token, a key, a ChatGPT plan token) only in
/// memory, so one restarted while the chat's agent slept lost it, and the chat's next turn ran signed
/// out ("Not logged in · Please run /login"). The app holds which connection each chat it started runs
/// on (``CloudAgentCredentialRefresher``); this follows the machines' handshakes
/// (``CloudMachineUpdates/handshake(_:machines:)``) and has it resend on each new one. A push of what the
/// session already holds restarts nothing there.
@MainActor
enum CloudCredentialResends {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.credentials")

    /// Follows the app's Cloud machines until the app quits (``AppServices/startCloud()``).
    @discardableResult
    static func start(_ services: AppServices) -> Task<Void, Never> {
        let machines = services.machines
        let refresher = services.cloud.agentCredentials.refresher
        // task-owner: app lifetime; follows the Cloud machines' handshakes
        return Task { @MainActor in
            let stream = ObservationStream({
                machines.cloud.map { ($0.machineID, CloudMachineUpdates.handshake($0, machines: machines)) }
            })
            for await handshakes in stream {
                for (machine, handshake) in handshakes where handshake != "refused" && refresher.linked(machine: machine, handshake: handshake) {
                    // task-owner: one resend per new link; each push has the attach client's own timeout
                    Task { @MainActor in
                        let sent = await refresher.resend(machine: machine)
                        logger.info("cloud machine \(machine, privacy: .public): new link, sent \(sent) chat credential(s) again")
                    }
                }
            }
        }
    }
}
