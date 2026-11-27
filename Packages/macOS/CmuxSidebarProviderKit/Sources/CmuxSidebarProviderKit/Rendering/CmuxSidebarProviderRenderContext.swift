import Foundation

/// Render-time context for values that should not be persisted in snapshots.
public struct CmuxSidebarProviderRenderContext: Codable, Equatable, Sendable {
    /// Current render time used for relative-date text.
    public var now: Date

    /// Creates a render context.
    public init(now: Date) {
        self.now = now
    }
}
