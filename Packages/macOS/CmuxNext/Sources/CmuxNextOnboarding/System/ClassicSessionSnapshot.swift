public import Foundation

/// A whole classic cmux session file, window by window.
public nonisolated struct ClassicSessionSnapshot: Codable, Equatable, Sendable {
    /// Classic's schema version (`version`); 1 for every classic release so far.
    public let version: Int
    /// When classic wrote it (`createdAt`, seconds since 1970); nil when absent.
    public let createdAt: Double?
    public let windows: [ClassicSessionWindow]

    public init(version: Int = 1, createdAt: Double? = nil, windows: [ClassicSessionWindow]) {
        self.version = version
        self.createdAt = createdAt
        self.windows = windows
    }

    /// Every workspace, window after window.
    public var workspaces: [ClassicSessionWorkspace] { windows.flatMap(\.workspaces) }
}
