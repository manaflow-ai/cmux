import Foundation

/// The projects step's text.
extension OnboardingStrings {
    static var projectsTitle: String { String(localized: "onboarding.projects.title", defaultValue: "Bring your projects", bundle: .module) }
    static var projectsSubtitle: String {
        String(localized: "onboarding.projects.subtitle",
               defaultValue: "Folders you worked in with coding agents. Each one you keep opens as a workspace.", bundle: .module)
    }
    static var projectsScanning: String { String(localized: "onboarding.projects.scanning", defaultValue: "Looking for projects…", bundle: .module) }
    static var projectsEmpty: String {
        String(localized: "onboarding.projects.empty", defaultValue: "No coding agent projects on this Mac yet.", bundle: .module)
    }
    static var projectsChoose: String { String(localized: "onboarding.projects.choose", defaultValue: "Choose a Folder…", bundle: .module) }
    static var projectsDropHint: String { String(localized: "onboarding.projects.dropHint", defaultValue: "Or drop a folder here.", bundle: .module) }
    static func projectsSessions(_ count: Int) -> String {
        String(format: String(localized: "onboarding.projects.sessions", defaultValue: "Sessions: %lld", bundle: .module), count)
    }
    /// One line for the guarded folders among the checked ones, e.g. "Desktop and Documents".
    static func projectsPrivacy(_ folders: [PrivacyFolder]) -> String {
        let names = ListFormatter.localizedString(byJoining: folders.map(privacyFolderName))
        return String(format: String(localized: "onboarding.projects.privacy",
                                     defaultValue: "macOS asks once for access to %@ when you continue.", bundle: .module), names)
    }
    static func privacyFolderName(_ folder: PrivacyFolder) -> String {
        switch folder {
        case .desktop: String(localized: "onboarding.projects.folder.desktop", defaultValue: "Desktop", bundle: .module)
        case .documents: String(localized: "onboarding.projects.folder.documents", defaultValue: "Documents", bundle: .module)
        case .downloads: String(localized: "onboarding.projects.folder.downloads", defaultValue: "Downloads", bundle: .module)
        case .iCloudDrive: String(localized: "onboarding.projects.folder.iCloudDrive", defaultValue: "iCloud Drive", bundle: .module)
        }
    }
}
