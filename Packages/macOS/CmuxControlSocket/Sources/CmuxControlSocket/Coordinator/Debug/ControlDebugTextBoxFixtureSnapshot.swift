#if DEBUG
public import Foundation

/// The state snapshot `debug.textbox.inline_fixture` returns after installing
/// the inline text-box fixture on a terminal panel.
public struct ControlDebugTextBoxFixtureSnapshot: Sendable, Equatable {
    /// The terminal panel's surface id.
    public let surfaceID: UUID
    /// The standardized attachment path (`""` when no attachment).
    public let path: String
    /// Whether the panel's text box is active.
    public let isTextBoxActive: Bool
    /// Whether the panel currently has a text-box input view.
    public let hasTextView: Bool
    /// Whether that input view is installed in a window.
    public let textViewHasWindow: Bool
    /// Whether the input view's window is the panel's hosted-view window.
    public let textViewMatchesPanelWindow: Bool
    /// The panel's text-box content.
    public let panelText: String
    /// The panel's attachment count.
    public let panelAttachmentCount: Int
    /// The input view's plain text.
    public let textViewText: String
    /// The input view's inline-attachment count.
    public let textViewAttachmentCount: Int

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - surfaceID: The terminal panel's surface id.
    ///   - path: The standardized attachment path (`""` when none).
    ///   - isTextBoxActive: Whether the panel's text box is active.
    ///   - hasTextView: Whether the panel has a text-box input view.
    ///   - textViewHasWindow: Whether that input view is in a window.
    ///   - textViewMatchesPanelWindow: Whether the input view's window is the
    ///     panel's hosted-view window.
    ///   - panelText: The panel's text-box content.
    ///   - panelAttachmentCount: The panel's attachment count.
    ///   - textViewText: The input view's plain text.
    ///   - textViewAttachmentCount: The input view's inline-attachment count.
    public init(
        surfaceID: UUID,
        path: String,
        isTextBoxActive: Bool,
        hasTextView: Bool,
        textViewHasWindow: Bool,
        textViewMatchesPanelWindow: Bool,
        panelText: String,
        panelAttachmentCount: Int,
        textViewText: String,
        textViewAttachmentCount: Int
    ) {
        self.surfaceID = surfaceID
        self.path = path
        self.isTextBoxActive = isTextBoxActive
        self.hasTextView = hasTextView
        self.textViewHasWindow = textViewHasWindow
        self.textViewMatchesPanelWindow = textViewMatchesPanelWindow
        self.panelText = panelText
        self.panelAttachmentCount = panelAttachmentCount
        self.textViewText = textViewText
        self.textViewAttachmentCount = textViewAttachmentCount
    }
}
#endif
