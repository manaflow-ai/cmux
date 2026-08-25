import Foundation

/// Immutable, event-safe representation of the selection owned by a surface.
/// The fields intentionally mirror the `surface.read_selection` contract while
/// keeping event production independent from any particular panel reader.
nonisolated struct SurfaceSelectionEventSnapshot: Equatable, Sendable {
    let hasSelection: Bool
    let kind: String
    let text: String
    let filePath: String?
    let lineRange: ClosedRange<Int>?
    let url: String?

    static func selected(
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

    static func none(
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

    func payload(identity: SurfaceSelectionEventIdentity) -> [String: Any] {
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
