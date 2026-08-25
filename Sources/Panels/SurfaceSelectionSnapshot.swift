import Foundation

/// Immutable selection context shared by every selectable panel kind.
public nonisolated struct SurfaceSelectionSnapshot: Equatable, Sendable {
    /// Maximum UTF-8 bytes exposed by one selection snapshot.
    public static let maximumTextBytes = 1_048_576

    private let selectedText: String?

    /// Whether the surface currently has a non-collapsed selection.
    public var hasSelection: Bool { selectedText != nil }

    /// Panel kind that produced this snapshot.
    public let kind: PanelType

    /// Selected text, or an empty string when there is no selection.
    public var text: String { selectedText ?? "" }

    /// Truncates text to the shared wire-safe selection budget and appends a
    /// visible ellipsis when truncation was required.
    public static func boundedText(_ text: String) -> String {
        guard text.utf8.count > maximumTextBytes else { return text }
        let marker = "…"
        let budget = max(0, maximumTextBytes - marker.utf8.count)
        return String(decoding: text.utf8.prefix(budget), as: UTF8.self) + marker
    }

    /// Standardized source path when the selection belongs to a document.
    public let filePath: String?

    /// One-based inclusive source lines when native text can map the range.
    public let lineRange: SurfaceSelectionLineRange?

    /// Visible page URL when the selection belongs to a browser surface.
    public let url: String?

    private init(
        selectedText: String?,
        kind: PanelType,
        filePath: String?,
        lineRange: SurfaceSelectionLineRange?,
        url: String?
    ) {
        self.selectedText = selectedText
        self.kind = kind
        self.filePath = filePath
        self.lineRange = lineRange
        self.url = url
    }

    /// Creates a snapshot containing a live selection.
    ///
    /// - Parameters:
    ///   - kind: Panel kind that owns the selection.
    ///   - text: Selected text. An empty string still represents a live,
    ///     non-collapsed selection whose DOM range has no textual content.
    ///   - filePath: Optional standardized source path.
    ///   - lineRange: Optional validated source line range.
    ///   - url: Optional visible page URL.
    public static func selected(
        kind: PanelType,
        text: String,
        filePath: String? = nil,
        lineRange: SurfaceSelectionLineRange? = nil,
        url: String? = nil
    ) -> Self {
        Self(
            selectedText: text,
            kind: kind,
            filePath: filePath,
            lineRange: lineRange,
            url: url
        )
    }

    /// Creates a snapshot with no live selection and no selection-only fields.
    ///
    /// - Parameters:
    ///   - kind: Panel kind that was inspected.
    ///   - filePath: Optional standardized source path.
    ///   - url: Optional visible page URL.
    public static func none(
        kind: PanelType,
        filePath: String? = nil,
        url: String? = nil
    ) -> Self {
        Self(
            selectedText: nil,
            kind: kind,
            filePath: filePath,
            lineRange: nil,
            url: url
        )
    }
}
