public import CmuxNextIcons

/// A Cloud chat's tab marks where it runs with a small cloud in the trailing badge slot (Austin 2026-11-22, cmux#51000:
/// "we can show the cloud icon in the tab tho for sure (this is something we need to show)"), never the leased
/// machine's name, which says nothing to the person ("lease-lease…", #45952), and never a glyph in or beside the
/// leading slot, which is for state only (Leo 2026-11-22, #50106). The badge's text still names it to VoiceOver
/// ("on Cloud"), and its color stays the machine's pick (`machineName`).
extension TabItem {
    /// Badges the tab with the machine it runs on: `badge`, colored by `name`, or the cloud for a
    /// `cloudChat` (a chat on a Cloud machine). A nil `badge` (this Mac) draws none.
    public mutating func setMachineBadge(_ badge: String?, name: String?, cloudChat: Bool) {
        (machineBadge, machineName, machineBadgeIcon) = (badge, name, nil)
        guard cloudChat, badge != nil else { return }
        setCloudChatBadge(name: name)
    }

    /// Badges a tab of this Mac that is a Cloud chat (cmux#51000): one whose Send is starting it, whose start
    /// failed, or that shows the started chat in place (`CloudFrontedChats`). `name`: the Cloud machine's color
    /// pick, once it has one.
    public mutating func setCloudChatBadge(name: String?) {
        (machineBadge, machineName, machineBadgeIcon) = (Strings.cloudMachineBadge, name, .cloud)
    }

    /// Badges a tab that shows a Cloud machine from this Mac (its desktop) with the word "Cloud", unless it
    /// already names a machine.
    public mutating func setCloudBadgeIfUnbadged() {
        guard machineBadge?.isEmpty ?? true else { return }
        (machineBadge, machineBadgeIcon) = (Strings.cloudMachineBadge, nil)
    }
}
