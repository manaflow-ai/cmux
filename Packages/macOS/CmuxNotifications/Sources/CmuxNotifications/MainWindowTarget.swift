public import Foundation

/// An opaque value handle for one registered main window, surfaced by
/// ``MainWindowContextResolving``. The coordinator never sees the concrete
/// `MainWindowContext` or `NSWindow`; it routes by `windowId` and consults the
/// workspace ids the window currently owns, exactly as the legacy
/// `context.tabManager.tabs` scan did.
public struct MainWindowTarget: Sendable, Equatable, Identifiable {
    /// The id of the registered main window.
    public let windowId: UUID
    /// The ids of the workspaces this window currently owns, in the window's
    /// own tab order (mirrors `context.tabManager.tabs.map(\.id)`).
    public let workspaceIds: [UUID]

    /// `Identifiable` conformance: the window id.
    public var id: UUID { windowId }

    /// Creates a window target handle.
    public init(windowId: UUID, workspaceIds: [UUID]) {
        self.windowId = windowId
        self.workspaceIds = workspaceIds
    }
}
