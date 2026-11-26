import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    enum RequestResourceKey: Hashable {
        case workspace(UUID)
        case windowDock(ObjectIdentifier)
    }
}
