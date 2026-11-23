import Foundation

/// When the agent chats' shared renderer is rebuilt in a fresh process, and what that needs.
///
/// Every chat page is `cmux-page://cmux.agent/`, one renderer for all (`CEFSwitches.processPerSitePageSchemes`).
/// Released chats' memory stays with that process: on the Mac bench after 100 chats (99 released, one shown, one
/// spare) it held 675 MB resident (326 MB footprint) against about 120-190 MB for a fresh one, and neither full
/// collections (``CEFPageRendererGC``), memory-pressure notices (`CEFHiddenPageTrim`) nor purges gave it back: the
/// allocators (Oilpan, PartitionAlloc) keep it until the process exits. So once that renderer has grown to
/// ``bound(baseline:)`` while nobody uses it, the App lets every page in it go (the shown chats keep their frame and
/// wake state, as a hidden idle chat's release does), waits for the process to exit, and shows those chats again
/// in a fresh one.
///
/// Off unless `CMUX_NEXT_CHAT_RENDERER_RECYCLE=1` (``isEnabled(_:)``), so the bench can compare both.
/// At most one recycle per ``cooldown``, for the chat renderer as a whole: a recycled renderer comes back under a
/// new client id.
public struct CEFChatRendererRecycle {
    /// The environment variable that turns recycling on (`1`; anything else leaves it off).
    public static let environmentKey = "CMUX_NEXT_CHAT_RENDERER_RECYCLE"
    /// The least growth worth rebuilding the shown chats.
    public static let growthFloorBytes = 256 << 20
    /// A fresh chat renderer's resident size, the most a renderer first seen at a check is assumed to have
    /// started at (the bench's fresh renderers: 120-190 MB).
    public static let freshBytes = 192 << 20
    /// The least time between two recycles.
    public static let cooldown: Duration = .seconds(600)
    /// The least time before another try once a page stopped one after its captures began (each try thaws every chat).
    public static let retryAfterAbort: Duration = .seconds(120)
    /// The input-free time after which the person counts as away while the app is active.
    public static let idleInput: Double = 30
    /// How long the old renderer gets to exit once its last page closed; the chats are built again after it either way.
    public static let exitLimit: Duration = .seconds(3)
    /// The pages' origin (``CEFRendererPage/origin``).
    public static let chatOrigin = "cmux-page://cmux.agent"

    /// A page of the renderer, as the App sees it.
    public enum Page: Equatable {
        /// A spare or pending-tab page (the New Tab pool's spare, the next Cmd-N's reserved page, a closed chat
        /// kept for Reopen Closed): it closes, and its pool makes another after the recycle.
        case spare
        /// A chat the hidden-page policy would let go (its turn is idle and known, it holds nothing unsaved, it
        /// is this Mac's chat and shows no crash notice); `shown` chats are built again after the recycle.
        case idleChat(key: String, shown: Bool)
        /// A page that keeps the renderer, and why.
        case keeps(String)
    }

    /// What a check does with one renderer.
    public enum Decision: Equatable {
        /// Let `release` go (their tabs keep frame and wake state), close the spares, then show `show` again.
        case recycle(release: [String], show: [String])
        /// Leave it, and why.
        case skip(String)
    }

    /// Each renderer's resident size when first seen (at most ``freshBytes``) or right after the last recycle.
    private var baselines: [Int32: Int] = [:]
    private var lastRecycle: ContinuousClock.Instant?
    private var lastAbort: ContinuousClock.Instant?

    public init() {}

    /// Whether `environment` turns recycling on.
    public static func isEnabled(_ environment: [String: String]) -> Bool { environment[environmentKey] == "1" }

    /// The resident size at which a renderer is recycled: twice its baseline, and at least ``growthFloorBytes`` more.
    public static func bound(baseline: Int) -> Int {
        let baseline = max(baseline, 0)
        return max(2 * baseline, baseline + growthFloorBytes)
    }

    /// The person is away: no input for ``idleInput``, or the app is not active.
    public static func personIdle(secondsSinceInput: Double, appActive: Bool) -> Bool {
        !appActive || secondsSinceInput >= idleInput
    }

    /// One agent tab's page (the App reads the rest): a New Tab page goes only as the untouched reserved one (the
    /// next Cmd-N's, which comes back in the fresh renderer); a chat goes unless the hidden-page policy keeps it
    /// (`exemption`).
    public static func tabPage(key: String, newTab: Bool, reservedUntouched: Bool, exemption: String?, shown: Bool) -> Page {
        if newTab { return reservedUntouched ? .spare : .keeps("a New Tab page") }
        if let exemption { return .keeps(exemption) }
        return .idleChat(key: key, shown: shown)
    }

    /// Whether the renderer's pages let it be recycled now: every page is a spare or an idle chat, the person
    /// is away and the app is not quitting. A renderer with no chat is left alone (nothing to win).
    public static func decide(_ pages: [Page], personIdle: Bool, shuttingDown: Bool) -> Decision {
        if shuttingDown { return .skip("shutting down") }
        if !personIdle { return .skip("the person is using the app") }
        var release: [String] = []
        var show: [String] = []
        for page in pages {
            switch page {
            case .spare: continue
            case .keeps(let why): return .skip(why)
            case .idleChat(let key, let shown):
                release.append(key)
                if shown { show.append(key) }
            }
        }
        return release.isEmpty ? .skip("no chat page") : .recycle(release: release, show: show)
    }

    /// Renderer `renderer` holds `resident` bytes: whether it is due (past its bound, out of the cooldown). The
    /// first sight records its baseline; renderers not in `live` are forgotten.
    public mutating func isDue(renderer: Int32, resident: Int, now: ContinuousClock.Instant, live: Set<Int32>) -> Bool {
        baselines = baselines.filter { live.contains($0.key) }
        let baseline = baselines[renderer] ?? min(resident, Self.freshBytes)
        baselines[renderer] = baseline
        if let lastRecycle, lastRecycle.duration(to: now) < Self.cooldown { return false }
        if let lastAbort, lastAbort.duration(to: now) < Self.retryAfterAbort { return false }
        return resident >= Self.bound(baseline: baseline)
    }

    /// A page stopped a recycle at `now` after its captures began.
    public mutating func aborted(at now: ContinuousClock.Instant) { lastAbort = now }

    /// A recycle ran at `now`.
    public mutating func recycled(at now: ContinuousClock.Instant) { lastRecycle = now }

    /// The fresh renderer's resident size once its pages were built again: its baseline.
    public mutating func settled(renderer: Int32, resident: Int) { baselines[renderer] = resident }
}
