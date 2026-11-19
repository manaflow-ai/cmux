public import CmuxNextIcons

/// A chat on a Cloud machine marks where it runs with a small cloud on its tab, never the leased
/// machine's name, which says nothing to the person ("lease-lease…", #45952). The badge's text
/// still names it to VoiceOver ("on Cloud"), and its color stays the machine's pick (`machineName`).
extension TabItem {
    /// Badges the tab with the machine it runs on: `badge`, colored by `name`, or the cloud for a
    /// `cloudChat` (a chat on a Cloud machine). A nil `badge` (this Mac) draws none.
    public mutating func setMachineBadge(_ badge: String?, name: String?, cloudChat: Bool) {
        (machineBadge, machineName, machineBadgeIcon) = (badge, name, nil)
        guard cloudChat, badge != nil else { return }
        machineBadge = Strings.cloudMachineBadge
        machineBadgeIcon = .cloud
    }
}
