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

    /// Whether the Cloud app server's create takes `autosize` (``CloudService/createMachine``): not yet,
    /// so every pick is nil until it does.
    static let createTakesAutosize = false

    /// The pick for the chat in `folder` (its tab `tab`: the title for the task kind, the agent for
    /// the Codex broker). Nil for no absolute folder and while the create takes no `autosize`
    /// (``createTakesAutosize``). Not behind Labs (Leo, 2026-10-30: "WHAT GOOD REASON DO WE HAVE IN
    /// THE FIRST PLACE TO KEEP THIS SHIT IN FUCKING LABS IF I FUCKING ASKED FOR THESE FUCKING FEATURES").
    func read(folder: String?, tab: TabModel?) async -> CloudWorkPick? {
        guard Self.createTakesAutosize, let folder, folder.hasPrefix("/") else { return nil }
        return await CloudWorkPick.read(folder: folder, text: tab?.displayTitle, harness: tab?.agentSession?.harness, work: services.work)
    }

    /// A bare create sized for the chat; with no pick, the plan's default as before.
    static func request(sizedFor pick: CloudWorkPick?) -> CloudMachineRequest {
        var request = CloudMachineRequest()
        request.autosize = pick?.autosize
        return request
    }
}
