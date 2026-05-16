import Foundation

/// Context menu actions that can be triggered from a tab item.
public enum SurfaceContextAction: String, CaseIterable, Sendable {
    case rename
    case clearName
    case copyIdentifiers
    case closeToLeft
    case closeToRight
    case closeOthers
    case move
    case moveToNewWorkspace
    case moveToLeftPane
    case moveToRightPane
    case newTerminalToRight
    case newBrowserToRight
    case reload
    case duplicate
    case togglePin
    case markAsRead
    case markAsUnread
    case toggleZoom
}

public struct SurfaceMoveDestination: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isEnabled: Bool

    public init(id: String, title: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
    }
}
