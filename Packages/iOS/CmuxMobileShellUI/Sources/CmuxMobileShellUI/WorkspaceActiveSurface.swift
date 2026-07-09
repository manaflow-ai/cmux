import Foundation

enum WorkspaceActiveSurface: Equatable {
    case terminal
    case chat
    case browser

    static func derive(isChatMode: Bool, hasChosenChatSession: Bool, hasActiveBrowser: Bool) -> Self {
        if isChatMode, hasChosenChatSession {
            return .chat
        }
        if hasActiveBrowser {
            return .browser
        }
        return .terminal
    }
}
