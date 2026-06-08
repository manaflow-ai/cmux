public import Foundation

/// Pure decision for whether a push for `workspaceId` should be delivered, given
/// the user's muted-workspace set. The authoritative enforcement is server-side
/// in the web push route (so a backgrounded/locked phone never renders a muted
/// workspace's banner); this mirror exists so the same rule is unit-testable on
/// the client and reusable for any local presentation gating.
///
/// A `nil`/empty workspace id is never muted (it cannot match a muted entry), so
/// it always delivers. Free function (not a namespace enum) per package policy.
public func pushShouldDeliver(workspaceId: String?, muted: Set<String>) -> Bool {
    guard let workspaceId, !workspaceId.isEmpty else { return true }
    return !muted.contains(workspaceId)
}
