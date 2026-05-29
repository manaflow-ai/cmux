import Foundation

public enum CMUXSidebarAction: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case openURL(String)
}
