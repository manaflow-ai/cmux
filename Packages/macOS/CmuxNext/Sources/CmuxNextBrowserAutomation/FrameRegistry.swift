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
    /// The read that starts when `inFlight` ends, shared by every caller
    /// that asked while `inFlight` ran (its result may predate their request).
    private var next: Task<[FrameRecord], Never>?

    /// A read that starts after this request, shared with concurrent callers.
    func refresh(_ webView: WKWebView) async -> [FrameRecord] {
        if let next { return await next.value }
        if let running = inFlight {
            let follow = Task { [weak self] () -> [FrameRecord] in
                _ = await running.value
                return await self?.read(webView) ?? []
            }
            next = follow
            return await follow.value
        }
        return await read(webView)
    }

    private func read(_ webView: WKWebView) async -> [FrameRecord] {
        let task = Task { await FrameTree.read(webView) }
        inFlight = task
        next = nil
        let result = await task.value
        if inFlight == task { inFlight = nil }
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
