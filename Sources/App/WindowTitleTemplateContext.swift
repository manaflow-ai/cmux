import Foundation

struct WindowTitleTemplateContext: Equatable, Sendable {
    var defaultTitle: String
    var activeWorkspace: String
    var activeDirectory: String
    var windowId: UUID
    var appName: String
}
