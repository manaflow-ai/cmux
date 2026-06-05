import Foundation

public enum CmuxSidebarSurfaceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview
    case rightSidebarTool
    case project
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CmuxSidebarSurfaceKind(rawValue: rawValue) ?? .unknown
    }
}

public struct CmuxSidebarSurface: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: CmuxSidebarSurfaceKind
    public var isFocused: Bool
    public var isPinned: Bool
    public var unreadCount: Int
    public var workingDirectory: String?

    public init(
        id: UUID,
        title: String,
        kind: CmuxSidebarSurfaceKind = .unknown,
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

    @_spi(CmuxHostTransport)
    public func filtered(for scopes: some Sequence<CmuxExtensionScope>) -> CmuxSidebarSurface {
        let scopeSet = Set(scopes)
        return CmuxSidebarSurface(
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
