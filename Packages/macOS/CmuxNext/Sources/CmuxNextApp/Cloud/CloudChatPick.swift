import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon

/// Automatic environment choice for a chat sent to Cloud (leo-workspace design/cloud-work-mode.md,
/// "Auto-sizing"): the machine a chat gets is chosen from the chat's folder (``CloudWorkPick``),
/// never by a prompt. Move to Cloud with no machine to reuse and New Cloud Machine asked from a
/// chat send the pick's `autosize` with the create, and the server answers the shape
/// (``CloudSizePick``, kept on the machine's session as ``CloudMachineSession/sizePick`` for the
/// hand-off). Not behind Labs: every caller sizes the chat's machine.
@MainActor
struct CloudChatPick {
    let services: AppServices

    /// The pick for the chat in `folder` (its tab `tab`: the title for the task kind, the agent for
    /// the Codex broker). Nil for no absolute folder and on the Cloud app server's link, whose
    /// create takes no `autosize` yet (``CloudService/createMachine``). Not behind Labs (Leo,
    /// 2026-10-30: "WHAT GOOD REASON DO WE HAVE IN THE FIRST PLACE TO KEEP THIS SHIT IN FUCKING
    /// LABS IF I FUCKING ASKED FOR THESE FUCKING FEATURES").
    func read(folder: String?, tab: TabModel?) async -> CloudWorkPick? {
        guard services.cloud.configuration.linkSource == .legacy,
              let folder, folder.hasPrefix("/") else { return nil }
        return await CloudWorkPick.read(folder: folder, text: tab?.displayTitle, harness: tab?.agentSession?.harness, work: services.work)
    }

    /// The chat tab of this Mac an action was asked from (the composer's New Cloud Machine names
    /// its tab); nil from anywhere else (the palette, the CLI, a chat on another machine).
    static func chatTab(_ invocation: ActionInvocation, _ services: AppServices) -> TabModel? {
        guard let target = invocation.target, target.kind == .tab, let (tab, _) = services.locateTab(target.id, onMachine: services.machines.local.machineID),
              let record = tab.agentSession, services.machines.daemon(forTab: tab).isLocal,
              !record.host.hasPrefix(MachineRegistry.registryHostPrefix) else { return nil }
        return tab
    }

    /// A bare create sized for the chat; with no pick, the plan's default as before.
    static func request(sizedFor pick: CloudWorkPick?) -> CloudMachineRequest {
        var request = CloudMachineRequest()
        request.autosize = pick?.autosize
        return request
    }

    /// The setup's request, sized for the chat only when the machine gets the chat's own
    /// repository: an empty VM or another repository keeps the plan's default size, as before.
    static func request(_ plan: CloudWorkspaceSetupWizard.Plan, sizedFor pick: CloudWorkPick?) -> CloudMachineRequest {
        var request = plan.request
        if let pick, let chosen = plan.repository, let own = pick.repo,
           chosen.owner.lowercased() == own.owner.lowercased(), chosen.name.lowercased() == own.name.lowercased() {
            request.autosize = pick.autosize
        }
        return request
    }
}
