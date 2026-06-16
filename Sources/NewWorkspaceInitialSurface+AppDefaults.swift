import CmuxWorkspaces
import Foundation

extension NewWorkspaceInitialSurface {
    var createsDedicatedWorkspace: Bool {
        switch self {
        case .terminal:
            return false
        case .browser, .guiMode:
            return true
        }
    }

    func defaultWorkspaceTitle(nextTabCount: Int) -> String {
        switch self {
        case .terminal:
            return "Terminal \(nextTabCount)"
        case .browser:
            return String(localized: "browser.newTab", defaultValue: "New tab")
        case .guiMode:
            return String(localized: "guiMode.workspace.home.title", defaultValue: "GUI Mode")
        }
    }
}
