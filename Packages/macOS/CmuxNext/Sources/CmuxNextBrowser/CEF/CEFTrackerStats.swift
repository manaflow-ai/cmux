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
    /// Geometry posts a window step held until its end (`FollowedViews`, a live resize on the frame tick): each went
    /// then (one more in `geometryPosts`) only if the fork had not read the page since.
    public var geometryPostsHeld = 0
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

    public init() {}

    /// The counters `debug.cef` reports as `tracker`, by key (milliseconds for the times). Per action = the change of
    /// each counter over it (scripts/cmux-next/pane-perf-terminal.py --browser).
    public var reportFields: [String: Double] {
        ["clip_reads": Double(clipReads), "occlusion_reads": Double(occlusionReads), "clip_builds": Double(clipBuilds),
         "clip_hits": Double(clipHits), "clip_ms": clipSeconds * 1_000, "geometry_posts": Double(geometryPosts),
         "geometry_posts_held": Double(geometryPostsHeld),
         "hosted_pages": Double(hostedPages), "hosting_refused": Double(hostingRefused), "geometry_skips": Double(geometrySkips)]
    }

    /// Monotonic seconds for timing a read.
    static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }
}
