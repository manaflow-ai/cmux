import Foundation

/// Immutable selection context shared by every selectable panel kind.
public nonisolated struct SurfaceSelectionSnapshot: Equatable, Sendable {
    public let hasSelection: Bool
    public let kind: PanelType
    public let text: String
    public let filePath: String?
    public let lineRange: SurfaceSelectionLineRange?
    public let url: String?

    public init(
        hasSelection: Bool,
        kind: PanelType,
        text: String,
        filePath: String?,
        lineRange: SurfaceSelectionLineRange?,
        url: String?
    ) {
        self.hasSelection = hasSelection
        self.kind = kind
        self.text = text
        self.filePath = filePath
        self.lineRange = lineRange
        self.url = url
    }

    public static func selected(
        kind: PanelType,
        text: String,
        filePath: String? = nil,
        lineRange: SurfaceSelectionLineRange? = nil,
        url: String? = nil
    ) -> Self {
        Self(
            hasSelection: true,
            kind: kind,
            text: text,
            filePath: filePath,
            lineRange: lineRange,
            url: url
        )
    }

    public static func none(
        kind: PanelType,
        filePath: String? = nil,
        url: String? = nil
    ) -> Self {
        Self(
            hasSelection: false,
            kind: kind,
            text: "",
            filePath: filePath,
            lineRange: nil,
            url: url
        )
    }
}
