public import CmuxNextIcons

/// A tab on a Cloud machine says where it runs in the trailing muted word slot, "Cloud", never the leased
/// machine's name, which says nothing to the person ("lease-lease…", #45952), and never a glyph in or beside the
/// leading slot, which is for state only (Leo 2026-11-22: "im not sure we want the cloud icon at the left. it makes
/// it stick out in a slight eyesore-y way. compared to the local ones which have no icon"). Its color stays the
/// machine's pick (`machineName`).
extension TabItem {
    /// Badges the tab with the machine it runs on: `badge`, colored by `name`, or "Cloud" for a
    /// `cloudChat` (a chat on a Cloud machine). A nil `badge` (this Mac) draws none.
    public mutating func setMachineBadge(_ badge: String?, name: String?, cloudChat: Bool) {
        (machineBadge, machineName, machineBadgeIcon) = (badge, name, nil)
        guard cloudChat, badge != nil else { return }
        machineBadge = Strings.cloudMachineBadge
    }

    /// Badges a tab that shows a Cloud machine from this Mac (its desktop) with the word "Cloud", unless it
    /// already names a machine.
    public mutating func setCloudBadgeIfUnbadged() {
        guard machineBadge?.isEmpty ?? true else { return }
        (machineBadge, machineBadgeIcon) = (Strings.cloudMachineBadge, nil)
    }
}
