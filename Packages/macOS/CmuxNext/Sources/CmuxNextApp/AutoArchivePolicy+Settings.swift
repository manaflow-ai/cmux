import CmuxNextSettings
import CmuxNextSidebar

extension AutoArchivePolicy {
    /// The policy `workspaces.autoArchive` sets; the defaults (suggest, 3 days) without settings.
    init(_ settings: AutoArchiveSettings?) {
        let settings = settings ?? AutoArchiveSettings()
        self.init(style: Style(rawValue: settings.style.rawValue) ?? .suggest, idleDays: settings.idleDays)
    }
}
