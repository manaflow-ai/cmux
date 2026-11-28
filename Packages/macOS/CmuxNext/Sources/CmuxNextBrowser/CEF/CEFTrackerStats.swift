import Foundation

/// Counters of the fork's page tracker reading this process's host views
/// since launch (`debug.cef` `tracker`). The fork re-reads a page's clip and
/// occlusion rects on every geometry update, which arrives several times per
/// display frame while a pane moves; these show how often that happens and
/// what answering it costs on the main thread.
public nonisolated struct CEFTrackerStats: Equatable, Sendable {
    /// `-cmuxClipPath` reads by the fork (one per geometry update of a shown page).
    public var clipReads = 0
    /// `-cmuxOcclusionRects` reads by the fork.
    public var occlusionReads = 0
    /// Clip shapes worked out (`CEFHostView.pageClip`): the walk of the
    /// view's ancestors plus, when one cuts into the page, the path operations.
    public var clipBuilds = 0
    /// Clip shape reads answered from the last shape (its inputs had not changed).
    public var clipHits = 0
    /// Total main-thread time in `pageClip`, in seconds.
    public var clipSeconds: Double = 0
    /// Distinct occlusion geometry revisions normalized for the fork.
    public var occlusionBuilds = 0
    /// Occlusion reads answered from the normalized geometry cache.
    public var occlusionHits = 0
    /// Total main-thread time spent normalizing occlusion geometry, in seconds.
    public var occlusionSeconds: Double = 0
    /// `CmuxParentViewGeometryDidChange` posts (each makes the fork update one page).
    public var geometryPosts = 0
    /// Hosted page views in a window now (`CEFHostedPageView`, fork API 26):
    /// pages that draw in a cmux window's layer tree. Live: a hosted view
    /// leaving its window (DevTools closed, a pane closed) is no longer counted.
    public var hostedPages = 0
    /// Layer hosting requests that left the page on its own window: the fork
    /// refused (no page window yet), or nothing could show its context.
    public var hostingRefused = 0
    /// Page update requests a page answered with no post: nothing the fork reads had changed
    /// since its last read (`CEFHostView.pagesNeedUpdate`).
    public var geometrySkips = 0
    /// Full page geometries worked out (`CEFHostGeometry`: ancestor walks for the rect, the visible rect and the clip
    /// inputs, and the window's occluders), by page update requests and fork reads together.
    public var geometryBuilds = 0
    /// Detached hosting (fork API 30): pages detached for a resize motion and attached again at its landing
    /// (``CEFLayerHosting/resizeMotion(active:)``).
    public var detaches = 0
    public var attaches = 0
    /// Window frame sync (fork API 32, ``CEFResizeFence``): window fences made, pages that joined one, pages whose frame
    /// at the new size carried it, pages that missed the GPU's deadline, and fences this app dropped at its own deadline
    /// with a page still out.
    public var resizeFences = 0
    public var resizeFenceJoined = 0
    public var resizeFencePresented = 0
    public var resizeFenceMissed = 0
    public var resizeFencesExpired = 0
    /// Main-thread seconds of the resizes that joined a fence (``CEFLayerHosting/pageViewResized()`` past its guard:
    /// the fence port, the fork's call and the deadline task), for its perf-hot budget per call.
    public var resizeFenceJoinSeconds = 0.0
    /// Seconds from each page's join to its `done` (presented or missed), summed, and the replies that came later than
    /// ``lateFenceReplySeconds``. Nightly c6ff12463 browser cells: a split or close whose page missed its fence showed
    /// no frame for about 520 ms (s9-browser-w10 close_right, s4-browser-w1 close_down) while the fence's own deadline
    /// was tens of ms; these say whether the page's reply (the fork holding its send right) or the commit was late.
    public var resizeFenceReplySeconds = 0.0
    public var resizeFenceRepliesLate = 0
    /// A reply later than this is late: well past any fence deadline (4 refreshes at 60 Hz and one more is ~83 ms).
    static let lateFenceReplySeconds = 0.1

    /// One page's `done` came `seconds` after it joined its fence.
    mutating func resizeFenceReplied(after seconds: Double) {
        resizeFenceReplySeconds += max(0, seconds)
        if seconds > Self.lateFenceReplySeconds { resizeFenceRepliesLate += 1 }
    }
    /// Pane commits a page drew ahead for with no fence (``CEFCommitPageWait``), by how each wait ended: the page
    /// answered that it laid out at the new size, the wait reached its bound first, or the page hid or left.
    public var commitWaitsAnswered = 0
    public var commitWaitsAtBound = 0
    public var commitWaitsLeft = 0
    /// Page answers of those waits (``CEFCommitLayoutWait/laidOut``) that came after the wait reported at its bound,
    /// evaluations that failed, and the seconds from each wait's start to the answer that ended it, summed.
    public var commitAnswersLate = 0
    public var commitAnswersFailed = 0
    public var commitAnswerSeconds = 0.0

    public init() {}

    /// The counters `debug.cef` reports as `tracker`, by key (milliseconds for the times). Per action = the change of
    /// each counter over it (scripts/cmux-next/pane-perf-terminal.py --browser).
    public var reportFields: [String: Double] {
        perPageHosting.merging(fieldsWithoutPages) { _, counter in counter }
    }

    /// Per shown page window, hosted (1) or not (0), by `hosted.<tab id>[.devtools]` (`CEFEngine.hostedPageFields`).
    var perPageHosting: [String: Double] = [:]

    /// These counters with the shown pages' hosting state for `debug.cef`.
    func with(hostedPages: [String: Double]) -> CEFTrackerStats {
        var stats = self
        stats.perPageHosting = hostedPages
        return stats
    }

    private var fieldsWithoutPages: [String: Double] {
        ["clip_reads": Double(clipReads), "occlusion_reads": Double(occlusionReads), "clip_builds": Double(clipBuilds),
         "clip_hits": Double(clipHits), "clip_ms": clipSeconds * 1_000, "geometry_posts": Double(geometryPosts),
         "hosted_pages": Double(hostedPages), "hosting_refused": Double(hostingRefused), "geometry_skips": Double(geometrySkips),
         "detaches": Double(detaches), "attaches": Double(attaches),
         "fences": Double(resizeFences), "fence_joined": Double(resizeFenceJoined),
         "fence_presented": Double(resizeFencePresented), "fence_missed": Double(resizeFenceMissed),
         "fences_expired": Double(resizeFencesExpired), "fence_join_ms": resizeFenceJoinSeconds * 1_000,
         "fence_reply_ms": resizeFenceReplySeconds * 1_000, "fence_reply_late": Double(resizeFenceRepliesLate),
         "commit_answered": Double(commitWaitsAnswered), "commit_at_bound": Double(commitWaitsAtBound),
         "commit_left": Double(commitWaitsLeft), "commit_answer_late": Double(commitAnswersLate),
         "commit_answer_failed": Double(commitAnswersFailed), "commit_answer_ms": commitAnswerSeconds * 1_000]
    }

    /// Monotonic seconds for timing a read.
    static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }
}
