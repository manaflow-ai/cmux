import Foundation

/// Immutable, event-safe representation of a surface-owned selection.
public struct SurfaceSelectionEventSnapshot: Equatable, Sendable {
    public let hasSelection: Bool
    public let kind: String
    public let text: String
    public let filePath: String?
    public let lineRange: ClosedRange<Int>?
    public let url: String?

    /// Creates a snapshot containing selected text and optional source context.
    public static func selected(
        kind: String,
        text: String,
        filePath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
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

    /// Creates a snapshot that explicitly reports that selection is absent.
    public static func none(
        kind: String,
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

    /// Encodes the snapshot using the event-bus payload field names.
    public func payload(identity: SurfaceSelectionEventIdentity) -> [String: Any] {
        var result: [String: Any] = [
            "has_selection": hasSelection,
            "kind": kind,
            "text": hasSelection ? text : "",
            "workspace_id": identity.workspaceId.uuidString,
            "workspace_ref": identity.workspaceRef,
            "surface_id": identity.surfaceId.uuidString,
            "surface_ref": identity.surfaceRef,
            "window_id": identity.windowId?.uuidString ?? NSNull(),
            "window_ref": identity.windowRef ?? NSNull()
        ]
        if let filePath {
            result["file_path"] = filePath
        }
        if let lineRange {
            result["line_range"] = [
                "start": lineRange.lowerBound,
                "end": lineRange.upperBound
            ]
        }
        if let url {
            result["url"] = url
        }
        return result
    }
}
