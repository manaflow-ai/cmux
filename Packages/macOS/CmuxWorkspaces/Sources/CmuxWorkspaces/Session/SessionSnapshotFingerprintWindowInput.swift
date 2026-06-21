public import Foundation

/// One window's contribution to the session-autosave fingerprint, flattened by
/// the app-side ``SessionSnapshotBuilding`` host so the package
/// ``SessionSnapshotBuilder`` can fold it without reaching into live god state.
///
/// The host has already sorted the windows by `windowId.uuidString` ascending,
/// computed each `TabManager`'s fingerprint, read the sidebar visibility,
/// quantized the sidebar width (`Int(sanitizedSidebarWidth(width).rounded())`),
/// mapped the sidebar selection to its legacy integer tag (`tabs == 0`,
/// `notifications == 1`), and captured the frame-fold closure. The service folds
/// these fields in the exact legacy order; it never reorders or re-derives.
public struct SessionSnapshotFingerprintWindowInput: Sendable {
    /// The window identifier (legacy `context.windowId`).
    public let windowId: UUID

    /// The window's `TabManager` autosave fingerprint (legacy
    /// `context.tabManager.sessionAutosaveFingerprint(...)`).
    public let tabManagerFingerprint: Int

    /// Whether the sidebar is visible (legacy `sidebarState.isVisible`).
    public let sidebarIsVisible: Bool

    /// The quantized sidebar width (legacy
    /// `Int(sanitizedSidebarWidth(Double(persistedWidth)).rounded())`).
    public let quantizedSidebarWidth: Int

    /// The sidebar-selection integer tag (legacy `tabs == 0`,
    /// `notifications == 1`).
    public let sidebarSelectionTag: Int

    /// Folds the window's frame contribution into the fingerprint hasher,
    /// reproducing the legacy `if let window { policy.hashFrame(window.frame,
    /// into: &hasher) } else { hasher.combine(-1) }` branch. The host captures the
    /// live window and the decision policy, so the package never sees `NSWindow`
    /// or `CGRect`.
    public let foldFrame: @Sendable (inout Hasher) -> Void

    /// Creates a per-window fingerprint input.
    ///
    /// - Parameters:
    ///   - windowId: the window identifier.
    ///   - tabManagerFingerprint: the window's `TabManager` autosave fingerprint.
    ///   - sidebarIsVisible: whether the sidebar is visible.
    ///   - quantizedSidebarWidth: the quantized sidebar width.
    ///   - sidebarSelectionTag: the sidebar-selection integer tag.
    ///   - foldFrame: folds the window's frame contribution into the hasher.
    public init(
        windowId: UUID,
        tabManagerFingerprint: Int,
        sidebarIsVisible: Bool,
        quantizedSidebarWidth: Int,
        sidebarSelectionTag: Int,
        foldFrame: @escaping @Sendable (inout Hasher) -> Void
    ) {
        self.windowId = windowId
        self.tabManagerFingerprint = tabManagerFingerprint
        self.sidebarIsVisible = sidebarIsVisible
        self.quantizedSidebarWidth = quantizedSidebarWidth
        self.sidebarSelectionTag = sidebarSelectionTag
        self.foldFrame = foldFrame
    }
}
