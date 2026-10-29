import CmuxNextCompat
public import CoreGraphics
public import QuartzCore

extension VSyncHub {
    /// A display link for the main thread's frame clock that rides `display`'s hub thread
    /// (Chrome's post-to-register-thread, `ui/display/mac/display_link_mac.mm`): armed while not
    /// paused, and each vsync becomes at most one pending main-run-loop post to `onTick`.
    ///
    /// - Parameters:
    ///   - display: The display to follow.
    ///   - onTick: Runs on main with the newest vsync that main has not taken yet.
    /// - Returns: The link, or nil when the display has no screen.
    public func mainLink(display: CGDirectDisplayID, onTick: @escaping @MainActor (Tick) -> Void) -> (any FrameLink)? {
        let link = MainLink(onTick: onTick, hop: mainHop, mediaTime: mediaTime)
        let mailbox = link.mailbox
        let mediaTime = mediaTime
        let post = postToMain
        let deliver: @MainActor @Sendable () -> Void = { [weak link] in link?.takeTick() }
        guard let subscription = subscribe(to: display, owner: "main frame clock", armed: true, onVSync: { tick in
            if mailbox.store(tick, postedAt: mediaTime()) { post(deliver) }
            return .more
        }) else { return nil }
        link.subscription = subscription
        return link
    }

    /// debug.wakeups' `vsync` counts: live links (displays with an armed subscriber), paused links, links
    /// made, hub threads running, main hop ticks, and the main hop's p50 and p99 in milliseconds (absent
    /// before the first tick).
    public var debugCounts: [String: Double] {
        var counts = ["live_links": Double(liveLinks), "paused_links": Double(pausedLinks), "links_made": Double(linksMade),
                      "threads": Double(runningThreads), "main_hop_ticks": Double(mainHop.count)]
        counts["main_hop_p50_ms"] = mainHop.percentile(0.5).map { $0 * 1000 }
        counts["main_hop_p99_ms"] = mainHop.percentile(0.99).map { $0 * 1000 }
        return counts
    }

    /// The main fan-out's hop over the last ``capacity`` ticks: what the hub thread adds before
    /// main sees a vsync, compared with a link on the main run loop. threading-model.md keeps the
    /// hop while its p99 stays under 0.1 ms in typing-frame-bench (the VSyncHub row).
    @MainActor
    public final class HopMeter {
        /// Ticks kept for the percentiles.
        public static let capacity = 256
        private var samples: [CFTimeInterval] = []
        private var next = 0
        /// Ticks measured since creation.
        public private(set) var count: UInt64 = 0

        init() {}

        func record(_ seconds: CFTimeInterval) {
            if samples.count < Self.capacity {
                samples.append(seconds)
            } else {
                samples[next] = seconds
                next = (next + 1) % Self.capacity
            }
            count += 1
        }

        /// The hop at `quantile` (0 to 1) of the recent ticks, in seconds; nil before the first tick.
        public func percentile(_ quantile: Double) -> CFTimeInterval? {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            let rank = (min(max(quantile, 0), 1) * Double(sorted.count - 1)).rounded(.up)
            return sorted[Int(rank)]
        }
    }

    /// The newest tick main has not taken yet: at most one main-run-loop post is pending.
    final class MainMailbox: Sendable {
        struct Pending: Sendable {
            let tick: Tick
            let postedAt: CFTimeInterval
        }

        private let pending = Mutex<Pending?>(nil)

        /// Keeps `tick` for main; returns true when nothing was pending, so the caller posts once.
        func store(_ tick: Tick, postedAt: CFTimeInterval) -> Bool {
            pending.withLock { pending in
                let wasEmpty = pending == nil
                pending = Pending(tick: tick, postedAt: wasEmpty ? postedAt : pending?.postedAt ?? postedAt)
                return wasEmpty
            }
        }

        func take() -> Pending? {
            pending.withLock { pending in
                defer { pending = nil }
                return pending
            }
        }
    }

    /// The ``FrameLink`` the main frame clock holds: unpausing arms its subscription, pausing
    /// disarms it, a rate request is its subscription's, ``relink()`` rebuilds the display's hub link,
    /// and invalidating cancels it.
    @MainActor
    final class MainLink: FrameLink {
        let mailbox = MainMailbox()
        var subscription: Subscription?
        private let onTick: @MainActor (Tick) -> Void
        private let hop: HopMeter
        private let mediaTime: @Sendable () -> CFTimeInterval

        init(onTick: @escaping @MainActor (Tick) -> Void, hop: HopMeter,
             mediaTime: @escaping @Sendable () -> CFTimeInterval) {
            self.onTick = onTick
            self.hop = hop
            self.mediaTime = mediaTime
        }

        var isPaused = false {
            didSet {
                guard isPaused != oldValue else { return }
                if isPaused { subscription?.disarm() } else { subscription?.arm() }
            }
        }

        func invalidate() {
            subscription?.cancel()
            subscription = nil
        }

        func requestFrameRate(_ range: CAFrameRateRange) {
            subscription?.requestFrameRate(range)
        }

        /// Replaces the display's hub link, which every subscriber of the display ticks on (a stall
        /// rebuild); false when no new link could be made.
        func relink() -> Bool {
            subscription?.relink() ?? false
        }

        /// The main run loop's pass for the pending tick.
        func takeTick() {
            guard let pending = mailbox.take() else { return }
            hop.record(mediaTime() - pending.postedAt)
            guard subscription != nil, !isPaused else { return }
            onTick(pending.tick)
        }
    }
}
