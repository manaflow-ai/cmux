// DEBUG and Demo builds only: the Feed scroll stress rig (frame timing, G-04).
#if DEBUG
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Observation

/// Launch settings for the Feed stress rig, from the environment
/// (`SIMCTL_CHILD_<NAME>` on a simulator):
/// - `CMUX_MOBILE_FEED_STRESS=N`: replace the Feed with N generated events (markdown,
///   code blocks, tables, quotes, math, open asks). On live data they merge
///   under the Mac's events and are saved in that account's Feed archive on
///   this device: use a test install (sign out, or delete the app, to clear).
/// - `CMUX_MOBILE_FEED_STRESS_LIVE=HZ`: live traffic while the rig runs: new events on
///   top, re-merged events with changed text (the terminal ledger), and reads,
///   HZ changes per second, each saved with `FeedArchive` as live mode does.
/// - `CMUX_MOBILE_FEED_AUTOSCROLL=PASSES`: scroll the Feed top to bottom and back
///   PASSES times at `CMUX_MOBILE_FEED_SCROLL_SPEED` pt/s (default 2400), recording
///   frame intervals per pass with `FrameIntervalLog` (needs `CMUX_MOBILE_FRAMELOG=1`).
///   Works on live data too.
public struct FeedStressConfig: Equatable, Sendable {
    public var seedCount: Int?
    public var liveHz: Double?
    public var autoscrollPasses: Int?
    public var scrollSpeed: Double
    /// Seconds to wait before scrolling (the Mac's events arriving, the pool warming).
    public var settle: Double
    /// Seconds of frame log before scrolling, with nothing moving.
    public var idleWindow: Double?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        seedCount = environment["CMUX_MOBILE_FEED_STRESS"].flatMap(Int.init)
        liveHz = environment["CMUX_MOBILE_FEED_STRESS_LIVE"].flatMap(Double.init)
        autoscrollPasses = environment["CMUX_MOBILE_FEED_AUTOSCROLL"].flatMap(Int.init)
        scrollSpeed = environment["CMUX_MOBILE_FEED_SCROLL_SPEED"].flatMap(Double.init) ?? 2400
        settle = environment["CMUX_MOBILE_FEED_SETTLE"].flatMap(Double.init) ?? 4
        idleWindow = environment["CMUX_MOBILE_FEED_IDLE_WINDOW"].flatMap(Double.init)
        logsChurn = environment["CMUX_MOBILE_FEED_CHURN_LOG"] == "1"
    }

    /// `CMUX_MOBILE_FEED_CHURN_LOG=1`: log what each store write changed (`FeedStore.logChange`).
    /// Off by default: it reflects over every changed event on the main thread, which the
    /// frame timings must not include.
    public var logsChurn: Bool

    public var isActive: Bool { seedCount != nil || liveHz != nil || autoscrollPasses != nil }
}

extension FeedStore {
    /// `count` varied events, newest first, deterministic for a given `now`.
    public static func stressItems(count: Int, now: Date) -> [FeedItem] {
        (0..<count).map { stressItem(index: $0, now: now.addingTimeInterval(-Double($0) * 37)) }
    }

    static func stressItem(index: Int, now: Date, revision: Int = 0) -> FeedItem {
        let bodies: [String] = [
            """
            Fixed the pricing table overflow (#\(index)). The grid now wraps:

            ```diff
            - grid-template-columns: repeat(3, 1fr);
            + grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            ```

            | Device | Before | After |
            | --- | --- | --- |
            | iPhone SE | clipped | 1 column |
            | iPad mini | 3 columns | 2 columns |

            All **14** tests pass (rev \(revision)).
            """,
            """
            **Finished:** extracted `LinkDialer` into `CmuxMobileTransport` (#\(index)).

            - 3 files changed, +118 −24
            - Swift and Rust link tests pass
            - Settings → Connection switches transport live
            """,
            """
            ## Plan for item \(index)

            1. **Pool.** Prewarm web views with the template.
            2. **Measure.** Heights measured in JavaScript off screen.
            3. **Cap.** Long bodies fade under *Show more*.

            > Native text stays the fallback.

            ```swift
            let height = renderer.cachedHeight(markdown: body, style: .body, width: column) // \(revision)
            for item in items where item.isRead { archive.append(item) }
            ```

            Measured on the simulator: no dropped frames over 40 events. \(String(repeating: "More detail follows here. ", count: index % 4 + 1))
            """,
            "Lint is clean after the import fix (#\(index), rev \(revision)). Pushing now.",
            """
            The backoff follows $d_n = \\min(d_{\\max}, d_0 2^n)$ with jitter (#\(index)). The fifth retry waits about $4\\,\\text{s}$.
            """,
            """
            The e2e job failed on `checkout.spec.ts` (#\(index)):

            ```text
            TimeoutError: locator('iframe[name^=__privateStripeFrame]') exceeded 30000ms
              at checkout.spec.ts:41:7
            ```

            Want me to retry?
            """,
        ]
        // What a real Feed carries (two Macs, Codex and Claude): answers, finished and failed
        // cards, terminal asks, permission cards with long commands, and questions.
        let kinds: [FeedItem.Kind] = [
            .response, .finished, .permission(stressPermission(index: index, revision: revision)), .needsInput,
            .response, .failed, .question(stressQuestion(index: index)), .response,
        ]
        let kind = kinds[index % kinds.count]
        let body: String
        switch kind {
        case .permission: body = "Codex wants to run a command in `~/Development/cmux` (#\(index))."
        case .question: body = "Before I tag the build I need a decision (#\(index))."
        default: body = bodies[index % bodies.count]
        }
        let codex = index % 2 == 0
        var item = FeedItem(
            id: "stress-\(index)", kind: kind,
            workspaceID: "ws-stress-\(index % 5)", tabID: "t-\(index % 7)",
            agentName: codex ? "Codex" : "Claude", harness: codex ? "codex" : "claude",
            workspaceTitle: ["cmux", "cmux.com", "web", "cmux-next-ios", "daemon"][index % 5], markdown: body,
            quote: index % 3 == 0 ? nil : .init("Request \(index): make the pricing page work on small phones and check dark mode too",
                                               author: index % 7 == 0 ? .agent : .you),
            createdAt: now
        )
        item.isRead = index % 4 != 0
        item.opensTerminal = item.kind == .needsInput
        item.macID = index % 3 == 0 ? "mac-stress-b" : "mac-stress-a"
        item.tabTitle = ["Fix login redirect", "Pricing page", "Feed perf", "Release notes", "zsh", "Claude", "Docs"][index % 7]
        if index % 9 == 4 { item.replies = ["Ship it after the e2e retry passes."] }
        return item
    }

    /// A permission card as Codex sends one: a long shell command in a code block.
    static func stressPermission(index: Int, revision: Int) -> ACPPermissionRequest {
        let command = """
        cd ~/Development/cmux && ./scripts/reload.sh --tag feed-\(index) --launch \\
          && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \\
             -destination 'platform=macOS' -derivedDataPath /tmp/cmux-feed-\(index) build \\
          | xcbeautify --quiet && git push origin HEAD:feat-feed-\(index) # rev \(revision)
        """
        return ACPPermissionRequest(
            id: "stress-perm-\(index)",
            toolCall: ACPToolCall(id: "stress-call-\(index)", title: "Run reload.sh", kind: .execute, status: .pending,
                                  rawInput: .object(["command": .string(command)])),
            options: [
                ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce),
                ACPPermissionOption(id: "always", name: "Always allow", kind: .allowAlways),
                ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce),
            ],
            cwd: "~/Development/cmux"
        )
    }

    static func stressQuestion(index: Int) -> AgentQuestion {
        AgentQuestion(
            id: "stress-q-\(index)",
            source: AgentQuestion.Source(harness: .claude, session: "t-\(index % 7)", permission: "stress-perm-q-\(index)", agentName: "Claude"),
            items: [
                AgentQuestion.Item(id: "channel", header: "Release", prompt: "Which channel should build \(index) go to first?", options: [
                    AgentQuestion.Option(id: "nightly", label: "Nightly", detail: "Everyone on nightly gets it tonight."),
                    AgentQuestion.Option(id: "rc", label: "Release candidate", detail: "Cut an rc and ask the team to dogfood."),
                    AgentQuestion.Option(id: "testflight", label: "TestFlight only"),
                ]),
            ]
        )
    }
}

/// Runs the configured stress: seeds the store, drives live traffic, scrolls.
@MainActor
final class FeedStressRig {
    static let shared = FeedStressRig(config: FeedStressConfig())
    let config: FeedStressConfig
    private var started = false
    private var liveTimer: Timer?
    private var tick = 0
    private var archive: FeedArchive?
    private var savePending = false

    init(config: FeedStressConfig) {
        self.config = config
    }

    /// Seeds and starts live traffic once (the Feed screen's first appearance).
    func start(store: FeedStore) {
        guard config.isActive, !started else { return }
        started = true
        if let count = config.seedCount {
            // On live data the seed goes under the Mac's events (history merge) and live
            // mode keeps its own save; with mock content the rig saves as live mode does.
            let seed = FeedStore.stressItems(count: count, now: Date())
            guard DeveloperOptions.mockContentEnabled else {
                // Live: after the coordinator loaded the account's Feed and the Mac's events.
                return seedWhenLive(store: store, seed: seed)
            }
            store.replaceAll(seed)
            // As live mode: every change is saved (`LiveCoordinator.scheduleFeedSave`).
            let archive = FeedArchive(url: FileManager.default.temporaryDirectory.appending(path: "feed-stress.json"))
            self.archive = archive
            store.onItemsChange = { [weak self, weak store] _ in
                guard let self, let store, !self.savePending else { return }
                self.savePending = true
                Task { @MainActor in
                    self.savePending = false
                    archive.saveInBackground(store.items)
                }
            }
        }
        startLive(store: store)
    }

    /// Merges `seed` once live mode owns the store (its save installed) and the Mac's events are in.
    private func seedWhenLive(store: FeedStore, seed: [FeedItem]) {
        if store.onItemsChange != nil, store.syncState == .live {
            store.mergeHistory(seed)
            return startLive(store: store)
        }
        withObservationTracking { _ = store.syncState } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                self.seedWhenLive(store: store, seed: seed)
            }
        }
    }

    private func startLive(store: FeedStore) {
        if let hz = config.liveHz, hz > 0 {
            let timer = Timer(timeInterval: 1 / hz, repeats: true) { [weak self, weak store] _ in
                MainActor.assumeIsolated {
                    guard let self, let store else { return }
                    self.liveEvent(store)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
        }
    }

    /// One live change, cycling through what the Mac sends.
    private func liveEvent(_ store: FeedStore) {
        tick += 1
        let count = max(store.items.count, 1)
        switch tick % 4 {
        case 0:
            // A new event on top (a Codex notification), as live mode adds one (`atTop: true`;
            // the store holds it while the Feed is scrolled away from the top).
            var item = FeedStore.stressItem(index: 10_000 + tick, now: Date())
            item.id = "stress-live-\(tick)"
            store.upsert(item, atTop: true)
        case 1:
            // The ledger re-read: an existing event's text changes in place.
            let index = (tick * 7) % count
            guard let existing = store.items[stress: index] else { return }
            var item = FeedStore.stressItem(index: Int(existing.id.split(separator: "-").last ?? "") ?? index, now: existing.createdAt,
                                            revision: tick)
            item.id = existing.id
            store.mergeHistory([item])
        case 2:
            // Read on the Mac.
            if let item = store.items[stress: (tick * 13) % count] { store.markRead(item.id) }
        default:
            // A history merge that changes nothing visible (a tree change).
            if let item = store.items[stress: (tick * 3) % count] { store.mergeHistory([item]) }
        }
    }
}

extension Array {
    subscript(stress index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif

#if DEBUG && os(iOS)
import CmuxMobileDesign
import OSLog
import SwiftUI
import UIKit

/// Scrolls the Feed's UIScrollView like a steady finger: down to the end and
/// back, `passes` times, one frame-interval window per direction.
@MainActor
final class FeedAutoScroller: NSObject {
    private weak var scrollView: UIScrollView?
    private let config: FeedStressConfig
    private var link: CADisplayLink?
    private var direction: CGFloat = 1
    private var pass = 0
    private var last: CFTimeInterval?
    private var started = false
    private var all: [FrameIntervalStats] = []

    init(config: FeedStressConfig) {
        self.config = config
    }

    func attach(_ scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        guard let passes = config.autoscrollPasses, passes > 0, !started else { return }
        started = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.config.settle ?? 4))
            // `CMUX_MOBILE_FEED_IDLE_WINDOW=S`: first S seconds untouched (what renders when nothing moves).
            if let idle = self?.config.idleWindow, idle > 0 {
                FrameIntervalLog.shared.begin("feed-idle")
                try? await Task.sleep(for: .seconds(idle))
                FrameIntervalLog.shared.end()
            }
            self?.startPass()
        }
    }

    private func startPass() {
        guard scrollView != nil else { return }
        FrameIntervalLog.shared.begin("feed-autoscroll-\(direction > 0 ? "down" : "up")-\(pass)")
        last = nil
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { link.invalidate(); return }
        let dt = last.map { link.timestamp - $0 } ?? 0
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_CELL_TIMING"] == "1", dt > 0.025 {
            FeedCellTiming.logger.notice("FEEDCELL long frame \(Int(dt * 1000), privacy: .public) ms at y=\(Int(scrollView.contentOffset.y), privacy: .public)")
        }
        #endif
        last = link.timestamp
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        var y = scrollView.contentOffset.y + direction * CGFloat(config.scrollSpeed * dt)
        let reachedEnd = direction > 0 ? y >= bottom : y <= top
        y = min(max(y, top), bottom)
        scrollView.contentOffset.y = y
        guard reachedEnd else { return }
        link.invalidate()
        self.link = nil
        if let stats = FrameIntervalLog.shared.end() { all.append(stats) }
        if direction < 0 { pass += 1 }
        direction = -direction
        if pass >= (config.autoscrollPasses ?? 0) {
            finish()
        } else {
            startPass()
        }
    }

    private func finish() {
        // One summary over every pass: merge by re-weighting is not exact, so log each and the worst.
        let worst = all.max { $0.p99Ms < $1.p99Ms }
        Logger(subsystem: "dev.cmux.mobile", category: "frames")
            .notice("FRAMELOG feed-autoscroll-done passes=\(self.pass, privacy: .public) worst=\(worst?.line ?? "-", privacy: .public)")
        // The rig (`verify/feedperf/rig.sh run`) waits for the app to exit.
        if ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_EXIT_WHEN_DONE"] == "1" {
            // The last window's line must be on disk before the process ends.
            FrameLogFile.flush()
            exit(0)
        }
    }
}

/// Hands the enclosing UIScrollView to `found` (the Feed's ScrollView).
struct EnclosingScrollViewProbe: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.found = found
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var found: ((UIScrollView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            if let scrollView = sequence(first: superview, next: { $0?.superview }).compactMap({ $0 as? UIScrollView }).first {
                found?(scrollView)
            }
        }
    }
}

#endif
