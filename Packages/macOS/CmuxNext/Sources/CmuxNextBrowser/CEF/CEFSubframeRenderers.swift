/// Which browsers have frames other than their main frame in each renderer, by renderer client id, from
/// the shim's SUBFRAME_RENDERER events: the browsers a renderer's abnormal end leaves a sad frame in.
/// Chrome reads the same from the frame nodes of the dead process
/// (chrome/browser/performance_manager/policies/discard_page_with_crashed_subframe_policy.cc).
///
/// A renderer's death detaches its frames too (WebContentsObserver::RenderFrameDeleted), and that can
/// come before the app sees the process end: a frame detached while its renderer was exiting is kept
/// for that end (``detached(_:client:browser:rendererExiting:)``). A frame detached while its renderer
/// ran (removed, navigated to another site, put in the back-forward cache) is forgotten, so a later
/// crash of that renderer does not reach its browser. Pure; the child monitor owns it on its queue.
nonisolated struct CEFSubframeRenderers: Sendable, Equatable {
    /// Client id -> browser id -> the identifiers of its frames attached to that renderer.
    private var frames: [Int32: [Int32: Set<String>]] = [:]
    /// Client id -> browsers whose frames the renderer's death detached before its end was seen.
    private var lost: [Int32: Set<Int32>] = [:]

    /// Frame `frame` of `browser`, not its main frame, attached to renderer `client`.
    mutating func attached(_ frame: String, client: Int32, browser: Int32) {
        frames[client, default: [:]][browser, default: []].insert(frame)
    }

    /// Frame `frame` of `browser` detached from renderer `client`; `rendererExiting` when that renderer had
    /// ended or was ending then (its death detached the frame).
    mutating func detached(_ frame: String, client: Int32, browser: Int32, rendererExiting: Bool) {
        guard frames[client]?[browser]?.remove(frame) != nil else { return }
        if frames[client]?[browser]?.isEmpty == true { frames[client]?[browser] = nil }
        if frames[client]?.isEmpty == true { frames[client] = nil }
        if rendererExiting { lost[client, default: []].insert(browser) }
    }

    /// Renderer `client` ended: the browsers it hosted frames for, which it forgets (a relaunched renderer
    /// of the same render process host starts with none).
    mutating func ended(client: Int32) -> Set<Int32> {
        let hosted: Set<Int32> = frames.removeValue(forKey: client).map { Set($0.keys) } ?? []
        return hosted.union(lost.removeValue(forKey: client) ?? [])
    }
}
