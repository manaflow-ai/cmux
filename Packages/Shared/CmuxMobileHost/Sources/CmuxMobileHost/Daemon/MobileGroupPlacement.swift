/// Where `workspace.move` files a workspace: its current group, no group,
/// or a group the policy found in this host's tree.
public enum MobileGroupPlacement: Hashable, Sendable {
    case keep
    case ungrouped
    case group(String)
}
