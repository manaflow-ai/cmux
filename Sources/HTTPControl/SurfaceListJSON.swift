import CmuxTerminalAccess
import Foundation

/// JSON wire-encoder for ``[SurfaceInfo]`` and ``SurfaceHandle``.
///
/// Lives in the app target so it stays close to its only consumer
/// (``HTTPControlRoutes``) and can call ``CmuxTerminalAccess`` model
/// types directly. The encoder emits the wire-shape required by
/// `GET /v1/surfaces` and is also reused as a stable string key for
/// the per-surface rate limiter (Task 1.15).
enum SurfaceListJSON {
    /// Encodes a list of ``SurfaceInfo`` values as the
    /// `{"surfaces": [...]}` envelope returned by `GET /v1/surfaces`.
    static func encode(_ surfaces: [SurfaceInfo]) -> [String: Any] {
        [
            "surfaces": surfaces.map { s in
                [
                    "handle": Self.encode(s.handle),
                    "uuid": s.uuid.uuidString,
                    "workspace": s.workspaceRef,
                    "title": s.title as Any,
                    "cols": s.cols,
                    "rows": s.rows,
                    "alt_screen": s.altScreen,
                    "focused": s.focused,
                    "semantic_available": s.semanticAvailable,
                ] as [String: Any]
            }
        ]
    }

    /// Encodes a ``SurfaceHandle`` as its canonical wire string.
    static func encode(_ handle: SurfaceHandle) -> String {
        switch handle {
        case .uuid(let u): return u.uuidString
        case .ref(let k, let n): return "\(k):\(n)"
        }
    }
}
