import Foundation

public enum CMUXSidebarSurfaceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview
    case rightSidebarTool
    case project
    case unknown
}

public struct CMUXSidebarSurface: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: CMUXSidebarSurfaceKind
    public var isFocused: Bool
    public var isPinned: Bool
    public var unreadCount: Int
    public var workingDirectory: String?

    public init(
        id: UUID,
        title: String,
        kind: CMUXSidebarSurfaceKind = .unknown,
        isFocused: Bool = false,
        isPinned: Bool = false,
        unreadCount: Int = 0,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isFocused = isFocused
        self.isPinned = isPinned
        self.unreadCount = unreadCount
        self.workingDirectory = workingDirectory
    }

    public func filtered(for scopes: some Sequence<CMUXExtensionScope>) -> CMUXSidebarSurface {
        let scopeSet = Set(scopes)
        return CMUXSidebarSurface(
            id: id,
            title: title,
            kind: kind,
            isFocused: isFocused,
            isPinned: isPinned,
            unreadCount: unreadCount,
            workingDirectory: scopeSet.contains(.workspacePaths) ? workingDirectory : nil
        )
    }
}
