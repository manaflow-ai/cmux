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
    /// What opening the group does, decided from its record and the workspaces open here.
    enum Plan: Equatable, Sendable {
        /// Show this workspace (a `ws_` resource id open on this Mac).
        case reveal(String)
        /// The group exists but none of its workspaces is open on this Mac.
        case notOpenHere
        /// The group is missing, or the account is not a member.
        case gone
    }

    /// The workspace a link opens: the named workspace when it is in the group and open here,
    /// else the group's items in position order, the first open here.
    ///
    /// - Parameters:
    ///   - reply: `group.get`'s value (`{group, items: [{workspace, position, …}]}`), nil when the read refused.
    ///   - named: The link's `/workspace/<ws_…>`, if any.
    ///   - openHere: Whether a `ws_` id is open on this Mac.
    nonisolated static func plan(reply: [String: Any]?, named: String?, openHere: (String) -> Bool) -> Plan {
        guard let reply, reply["group"] is [String: Any] else { return .gone }
        let items = (reply["items"] as? [[String: Any]] ?? [])
            .compactMap { item -> (String, Int)? in
                guard let ws = item["workspace"] as? String else { return nil }
                return (ws, (item["position"] as? NSNumber)?.intValue ?? Int.max)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        if let named, items.contains(named), openHere(named) { return .reveal(named) }
        if let first = items.first(where: openHere) { return .reveal(first) }
        return .notOpenHere
    }

    /// Reads the group, then shows its workspace as the run's end: one task on main in the run's class
    /// (`userBlocking` for the person's click, ``ActionRegistry/trackWork(owner:on:tracked:file:line:_:then:)``).
    @MainActor
    static func open(_ id: String, workspace named: String?, intent: WindowActivation.Intent, services: AppServices) {
        services.registry.trackWork(owner: "CloudGroupLink.open", on: services.mainWork) {
            await plan(id, named: named, services: services)
        } then: { result in
            switch result {
            case .success(.reveal(let ws)):
                guard let workspace = services.machines.allWorkspaces.map(\.0).first(where: { $0.resourceID?.rawValue == ws }),
                      let window = services.windows.reveal(workspaceID: workspace.id), let nsWindow = window.window else { break }
                services.showJumpWindow(nsWindow, intent)
                return nil
            case .success(.notOpenHere):
                services.registry.refuse(RefusalStrings.cloudGroupNotOpenHere)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.cloudGroupNotOpenHere)
            case .success(.gone), .failure:
                break
            }
            services.registry.refuse(RefusalStrings.linkTargetGone)
            return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
        }
    }

    /// The group's record from cmux Cloud (`group.get`, the feed's main-actor call; its network read runs off
    /// main), planned against the workspaces open here when it answers.
    @MainActor
    private static func plan(_ id: String, named: String?, services: AppServices) async -> Plan {
        let reply: [String: Any]?
        do {
            reply = try CloudPairingSource.okValue(try await services.feed.call("v1/read", ["op": "group.get", "params": ["group": id]])) as? [String: Any]
        } catch {
            reply = nil
        }
        let open = services.machines.allWorkspaces.map(\.0)
        return plan(reply: reply, named: named) { ws in open.contains { $0.resourceID?.rawValue == ws } }
    }
}
