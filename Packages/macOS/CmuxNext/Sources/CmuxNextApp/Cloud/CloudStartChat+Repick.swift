import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Another machine picked for a Cloud chat whose first send has not run (`cloud.repickChat`,
/// ``AgentPaneCloudRepick``): the chat moves there and its first prompt is sent again there. The send is
/// pinned to the picked machine (`cmux link start-chat pin`, which makes it the Mac workspace's machine
/// too), the chat's folder on this Mac is copied there as for the first try, the chat opens there with
/// the same prompt, and its tab on the machine it was on closes.
///
/// Leo, 2026-10-31: he "picked zesty-indigo-lemur in the machine picker, but the chat stayed on
/// sr2-tunnel-probe (the location menu's top row and the tab title still show sr2-tunnel-probe) and
/// failed again". The picker had only started a new empty chat through that machine's acpmux, or
/// opened the picked machine and waited; nothing moved the chat or sent its prompt again.
extension CloudStartChat {
    /// The page's runner for `cloud.repickChat`: `view` is the pane of the chat on the machine it was on.
    static func repickRunner(_ tabs: AgentTabStore, services: AppServices) -> @MainActor (AgentPaneView?, AgentPaneCloudRepick) async -> [String: Any] {
        { [weak tabs, weak services] view, repick in
            guard let services else { return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled") }
            guard let view, let tabs, let key = tabs.views.first(where: { $0.value === view })?.key,
                  let started = tabs.pageChats.cloudStarted[key], let (tab, _) = services.locateTab(key) else {
                // No chat a start opened: the page does what a pick did before.
                return AgentPaneReply.failure(code: "not_a_cloud_start", message: "not_a_cloud_start")
            }
            return await CloudStartChat(services: services).repick(repick, started: started, key: key, tab: tab)
        }
    }

    /// Moves the chat a start opened (tab `key`, `tab`) to the machine `repick` names and sends its
    /// first prompt there; the page's reply.
    func repick(_ repick: AgentPaneCloudRepick, started: AgentPaneCloudStarted, key: String, tab: TabModel) async -> [String: Any] {
        if let refusal = Self.refusal(services) { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let listed = services.cloud.listedMachineIDs
        let machines = services.machines.cloud.filter { listed.contains($0.machineID) }
            .map { (id: $0.machineID, title: $0.machine.title, slug: $0.machine.slug) }
        guard let target = repick.machineID(in: machines) else {
            return AgentPaneReply.failure(code: "not_a_cloud_start", message: "not_a_cloud_start")
        }
        // The machine it is on already: nothing moves.
        guard target != started.machineID else { return AgentPaneReply.success(["machine": services.machines.session(target)?.machine.title ?? ""]) }
        let toastID = "cloud-start-" + tab.id
        CloudMove.toast(services, toastID, CloudMoveStrings.moving, duration: .seconds(600))
        do {
            // Only under the account the send began in (+Machine).
            try Self.checkAccount(started.account, now: services.cloud.account, listCurrent: services.cloud.hasLoadedCurrentMachines)
            guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
            let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
            // The pick wins over the send's first machine: the plan now names the picked one.
            _ = try Self.checked(await cli.startChatPin(key: started.start.key, account: Self.accountText(started.account),
                                                        machine: target, workspace: started.workspace))
            let old = services.machines.daemon(forTab: tab)
            let origin = Origin(tab: tab, chat: started.chat, workspace: started.workspace, account: started.account) { [services] in
                // The chat's tab on the machine it was on, whose first send never ran.
                services.agentTabs.pageChats.cloudStarted[key] = nil
                do {
                    try await old.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
                } catch {
                    services.cloud.logger.error("cloud start chat: closing the chat's old tab failed: \(String(describing: error), privacy: .public)")
                }
            }
            let machine = try await run(started.start, from: origin) { _ in }
            CloudMove.toast(services, toastID, CloudMoveStrings.moved(machine), duration: .seconds(6))
            return AgentPaneReply.success(["machine": machine])
        } catch {
            let message = (error as? CloudMove.Failure)?.message ?? (error as? ActionFailure)?.message
                ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
            services.cloud.logger.error("cloud start chat repick failed: \(message, privacy: .public)")
            CloudMove.toast(services, toastID, message, duration: .seconds(12))
            return AgentPaneReply.failure(code: "cloud_start_failed", message: message)
        }
    }
}
