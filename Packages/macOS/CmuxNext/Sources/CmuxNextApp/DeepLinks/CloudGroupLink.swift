import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextDesign
import Foundation

/// `link.open` for a cloud group link (`cmux://group/grp_…[/workspace/ws_…]`,
/// plans/cmux-next/cloud-groups-DESIGN.md slice 1) whose workspace this Mac does not show yet.
///
/// The group's record lives in cmux Cloud (TeamDO), so this reads it with the signed-in
/// account (`group.get`) and shows the first of its workspaces that is open on this Mac,
/// the named one first. A group the account cannot read refuses as gone; a group none of
/// whose workspaces is open here says so. It never creates, moves or starts anything.
enum CloudGroupLink {
    @MainActor
    static func open(_ id: String, workspace named: String?, intent: WindowActivation.Intent, services: AppServices) {
        services.registry.track(Task { @MainActor () -> ActionWorkFailure? in
            let reply: [String: Any]?
            do {
                reply = try CloudPairingSource.okValue(try await services.feed.call("v1/read", ["op": "group.get", "params": ["group": id]])) as? [String: Any]
            } catch {
                reply = nil
            }
            let open = services.machines.allWorkspaces.map(\.0)
            let plan = DeepLink.groupPlan(reply: reply, named: named) { ws in open.contains { $0.resourceID?.rawValue == ws } }
            switch plan {
            case .reveal(let ws):
                guard let workspace = open.first(where: { $0.resourceID?.rawValue == ws }),
                      let window = services.windows.reveal(workspaceID: workspace.id), let nsWindow = window.window else { break }
                services.showJumpWindow(nsWindow, intent)
                return nil
            case .notOpenHere:
                services.registry.refuse(RefusalStrings.cloudGroupNotOpenHere)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.cloudGroupNotOpenHere)
            case .gone:
                break
            }
            services.registry.refuse(RefusalStrings.linkTargetGone)
            return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
        })
    }
}
