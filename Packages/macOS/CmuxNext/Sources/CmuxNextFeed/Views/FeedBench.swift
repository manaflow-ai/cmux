#if DEBUG
import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The Feed list's scroll and live-update bench (scripts/cmux-next/feed-perf.py), DEBUG builds
/// only, the Mac twin of the iPhone rig's `CMUX_MOBILE_FEED_STRESS`. With
/// `CMUX_NEXT_FEED_BENCH=<path>` in the environment, the first Feed host shown (`FeedHostView`,
/// whatever draws its list) starts it once; the bench finds the list's scroll view itself:
///
/// 1. puts `CMUX_NEXT_FEED_BENCH_COUNT` (300) believable events in the model, as owner events;
/// 2. runs three phases of `CMUX_NEXT_FEED_BENCH_SECONDS` (6) each, one second apart:
///    `scroll` (down and back at `CMUX_NEXT_FEED_BENCH_SPEED`, 2400 pt/s, one step per display
///    frame, as a trackpad fling moves the clip view), `scroll-live` (the same while
///    `CMUX_NEXT_FEED_BENCH_LIVE_HZ`, 4, events arrive each second: new ones, and agents
///    repeating a notice that the owner coalesces), and `live` (events only, the list at rest);
/// 3. writes each phase's display-frame intervals and the list's render and reload counts to
///    `<path>` as JSON.
///
/// Everything ticks on display frames; nothing runs without the variable.
@MainActor
final class FeedBench {
    struct Settings {
        var output: URL
        var count = 300
        var seconds = 6.0
        var speed = 2_400.0
        var liveHz = 4.0

        init?(environment: [String: String]) {
            guard let path = environment["CMUX_NEXT_FEED_BENCH"], !path.isEmpty else { return nil }
            output = URL(fileURLWithPath: path)
            count = environment["CMUX_NEXT_FEED_BENCH_COUNT"].flatMap(Int.init) ?? count
            seconds = environment["CMUX_NEXT_FEED_BENCH_SECONDS"].flatMap(Double.init) ?? seconds
            speed = environment["CMUX_NEXT_FEED_BENCH_SPEED"].flatMap(Double.init) ?? speed
            liveHz = environment["CMUX_NEXT_FEED_BENCH_LIVE_HZ"].flatMap(Double.init) ?? liveHz
        }
    }

    private let settings: Settings
    private let model: FeedModel
    private weak var host: NSView?
    private var scroll: NSScrollView? {
        var best: NSScrollView?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(walk)
        }
        host.map(walk)
        return best
    }
    /// The list's render and reloaded-row counts (zero for a list that keeps none).
    private var counters: (renders: Int, reloaded: Int) {
        var found: (any FeedBenchCounting)?
        func walk(_ view: NSView) {
            if let rows = view as? any FeedBenchCounting { found = rows }
            view.subviews.forEach(walk)
        }
        host.map(walk)
        return (found?.renderCount ?? 0, found?.reloadedTotal ?? 0)
    }
    private let phases = ["scroll", "scroll-live", "live"]
    private var phase = -1
    private var phaseStart: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var liveDue: CFTimeInterval = 0
    private var serial = 0
    private var direction: CGFloat = 1
    private var intervals: [String: [Double]] = [:]
    private var renders: [String: Int] = [:]
    private var reloaded: [String: Int] = [:]
    private var mark = (renders: 0, reloaded: 0)
    private lazy var client = FrameClient(owner: "feed.bench", isAnimation: false, on: .app) { [weak self] tick in
        self?.tick(tick) ?? false
    }

    init(settings: Settings, model: FeedModel, host: NSView) {
        self.settings = settings
        self.model = model
        self.host = host
    }

    func start() {
        let now = Date()
        model.debugInject((0..<settings.count).map { Self.item($0, now: now.addingTimeInterval(-Double(settings.count - $0) * 47)) })
        serial = settings.count
        phaseStart = CACurrentMediaTime() + 1.5
        client.activate()
    }

    private func tick(_ tick: FrameTick) -> Bool {
        let now = CACurrentMediaTime()
        defer { lastFrame = tick.timestamp }
        if now < phaseStart { return true }
        if phase < 0 || now >= phaseStart + settings.seconds {
            if phase >= 0 { close(phases[phase]) }
            phase += 1
            guard phase < phases.count else {
                write()
                return false
            }
            phaseStart = now + (phase == 0 ? 0 : 1)
            liveDue = phaseStart
            mark = counters
            return true
        }
        let name = phases[phase]
        if lastFrame > 0 { intervals[name, default: []].append((tick.timestamp - lastFrame) * 1_000) }
        if name != "scroll", settings.liveHz > 0 {
            while liveDue <= now {
                liveDue += 1 / settings.liveHz
                serial += 1
                // Every third change is an agent repeating its notice (the owner coalesces it).
                let index = serial % 3 == 0 ? serial % 40 : serial
                model.debugInject([Self.item(index, now: Date())])
            }
        }
        if name != "live", let scroll, let document = scroll.documentView {
            let clip = scroll.contentView
            let maxY = max(0, document.frame.height - clip.bounds.height)
            var y = clip.bounds.origin.y + direction * CGFloat(settings.speed * tick.elapsed)
            if y >= maxY { y = maxY; direction = -1 }
            if y <= 0 { y = 0; direction = 1 }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        return true
    }

    private func close(_ name: String) {
        let now = counters
        renders[name] = now.renders - mark.renders
        reloaded[name] = now.reloaded - mark.reloaded
    }

    private func write() {
        let report: [String: Any] = [
            "count": settings.count, "seconds": settings.seconds, "speed": settings.speed, "live_hz": settings.liveHz,
            "phases": phases.map { name in
                ["name": name, "intervals_ms": intervals[name] ?? [], "renders": renders[name] ?? 0, "rows_reloaded": reloaded[name] ?? 0]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) else { return }
        let output = settings.output
        // task-owner: one report write off the main thread; it ends when the file is written
        Task.detached(priority: .utility) { try? data.blockingWrite(to: output, options: .atomic) }
    }

    /// A varied, believable event: finished turns, failures, approvals, CI, questions and terminal
    /// waits, from several agents in several workspaces and tabs.
    static func item(_ index: Int, now: Date) -> FeedItem {
        let workspaces = ["api-server", "cmux-next", "docs-site", "infra", "billing"]
        let tabs = ["Claude Code", "Codex", "Fix login redirect", "Feed perf", "Release notes", "zsh"]
        let harnesses = ["Claude Code", "Codex", "Gemini CLI"]
        let workspace = workspaces[index % workspaces.count]
        let harness = harnesses[index % harnesses.count]
        let poster = FeedPoster(kind: .agent, label: workspace, harness: harness, host: "MacBook Pro")
        let context = FeedContext(host: "MacBook Pro", workspace: workspace, tab: tabs[(index / 2) % tabs.count])
        let id = "fi_bench_\(index)"
        // What today's posters send: the permission bridge names its poster "Agent" and only an ACP
        // session, GitHub titles its items "GitHub", a terminal hand-off is a system notice.
        let bridge = FeedPoster(kind: .agent, label: "Agent")
        let session = FeedContext(host: "inst_mac", acpSession: "ses_\(index % 7)")
        switch index % 10 {
        case 6:
            return FeedItem(id: id, title: "Allow Bash?", body: "git push --force-with-lease origin feat/login",
                            prompt: .approve(.init(action: .init(type: .command, summary: "Bash",
                                                                 command: "git push --force-with-lease origin feat/login", tool: "Bash"))),
                            context: session, poster: bridge, state: .answered,
                            answer: FeedAnswerRecord(value: .approve(.init(.allow, scope: .once)), by: "usr_me", device: "", at: now),
                            readAt: now, createdAt: now, closedAt: now)
        case 7:
            return FeedItem(id: id, title: "An agent asks: Which branch should the release go to?",
                            context: session, poster: bridge, createdAt: now)
        case 8:
            return FeedItem(id: id, title: "GitHub", body: "manaflow-ai/cmux#\(26_400 + index % 90)",
                            context: FeedContext(url: URL(string: "https://github.com/manaflow-ai/cmux/pull/\(26_400 + index % 90)")),
                            poster: FeedPoster(kind: .integration, label: "GitHub"), createdAt: now)
        case 9:
            return FeedItem(id: id, title: "Claude Code finished", context: FeedContext(terminal: "term_\(index % 9)"),
                            poster: FeedPoster(kind: .system, label: "terminal"), createdAt: now)
        default:
            break
        }
        switch index % 6 {
        case 0:
            return FeedItem(id: id, title: "Finished: updated FeedModel.swift and 3 tests",
                            body: "Ran `swift test --filter FeedModelTests`: 42 passed.\nChanged Sources/Feed/FeedModel.swift (+38 −12).",
                            thread: "\(harness):\(workspace)", context: context, poster: poster, createdAt: now)
        case 1:
            return FeedItem(id: id, title: "Turn failed: build error in LoginView.swift",
                            body: "error: cannot find 'session' in scope (LoginView.swift:88)", priority: .high,
                            thread: "\(harness):\(workspace)", context: context, poster: poster, createdAt: now)
        case 2:
            return FeedItem(id: id, title: "Allow rm -rf build && npm run build?",
                            prompt: .approve(.init(action: .init(type: .command, summary: "Clean and rebuild",
                                                                 command: "rm -rf build && npm run build", cwd: "~/src/\(workspace)",
                                                                 tool: "Bash"), scopes: [.once, .session])),
                            thread: "\(harness):\(workspace)", context: context, poster: poster,
                            state: .answered, readAt: now, createdAt: now, closedAt: now)
        case 3:
            return FeedItem(id: id, title: "CI passed on feat/login (12 checks)", body: "All checks green in 6m 41s.",
                            context: FeedContext(workspace: workspace), poster: FeedPoster(kind: .integration, label: "GitHub Actions"),
                            createdAt: now)
        case 4:
            return FeedItem(id: id, title: "Asked: Which sign-in method should the CLI use?",
                            prompt: .question(.init(question: "Which sign-in method should the CLI use?", suggestions: ["Device code", "Browser"])),
                            thread: "\(harness):\(workspace)", context: context, poster: poster,
                            state: .answered, readAt: now, createdAt: now, closedAt: now)
        default:
            return FeedItem(id: id, title: "Needs input in the terminal", body: "Codex is waiting for an approval in its TUI.",
                            context: context, poster: poster, createdAt: now)
        }
    }
}

/// A Feed list that counts its renders and the rows they reloaded.
@MainActor
protocol FeedBenchCounting: AnyObject {
    var renderCount: Int { get }
    var reloadedTotal: Int { get }
}

extension FeedModel {
    /// The bench's events, through the same path as the owner's (one event per call).
    func debugInject(_ items: [FeedItem]) {
        var stamped: [FeedItem] = []
        for var item in items {
            if let current = self.item(item.id) {
                item.count = current.count + 1
                item.createdAt = current.createdAt
                item.revision = current.revision + 1
            }
            stamped.append(item)
        }
        handle(.event(FeedEvent(revision: revision + 1, change: .items(stamped))))
    }
}
#endif
