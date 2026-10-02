import Foundation
import WebKit

/// The last frame tree read per tab, so a call that names a frame finds it
/// without a walk; callers that need the current tree share one read that
/// starts after their request.
@MainActor
final class FrameRegistry {
    private var frames: [String: FrameRecord] = [:]
    private var ordered: [FrameRecord] = []
    private var inFlight: Task<[FrameRecord], Never>?

    /// A fresh read (shared with concurrent callers whose request came first).
    func refresh(_ webView: WKWebView) async -> [FrameRecord] {
        if let inFlight { return await inFlight.value }
        let task = Task { await FrameTree.read(webView) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        ordered = result
        frames = Dictionary(result.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        return result
    }

    /// The frame with `id`, from the last read, or a fresh read on a miss.
    func frame(_ id: String, in webView: WKWebView) async -> FrameRecord? {
        if let hit = frames[id] { return hit }
        return await refresh(webView).first { $0.frameID == id }
    }

    var mainFrameID: String? { ordered.first?.frameID }
}
