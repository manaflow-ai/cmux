// DEBUG and Demo builds only: the list scroll stress rig (verify/listperf/).
#if os(iOS) && DEBUG
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
import Darwin
import OSLog
import QuartzCore
import UIKit

/// Seeds one list with `ListStressSettings` (mock mode), opens it, then scrolls its
/// UIScrollView like a steady finger, top to bottom and back, with one
/// `FrameIntervalLog` window per direction (`<screen>-down-N`, `<screen>-up-N`).
/// The Feed has its own rig (`FeedStress.swift`); this one covers the other lists.
@MainActor
final class ListStressRig: NSObject {
    private let settings: ListStressSettings
    private let shell: ShellModel
    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var direction: CGFloat = 1
    private var pass = 0
    private var last: CFTimeInterval?
    private var passStart: CFTimeInterval?
    /// Where the rig last put the offset: a list that moves it back (a transcript following
    /// its bottom) is logged, and a pass ends after 90 s either way.
    private var placed: CGFloat?
    private var fights = 0
    /// `CMUX_MOBILE_LIST_PAN=1`: the passes pan sideways (the diff's unwrapped code).
    private var horizontal: Bool { settings.pans }
    private var live: Task<Void, Never>?
    let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")

    init(settings: ListStressSettings, shell: ShellModel) {
        self.settings = settings
        self.shell = shell
    }

    static func runIfConfigured(shell: ShellModel) async {
        let settings = ListStressSettings.shared
        guard let screen = settings.screen else { return }
        let rig = ListStressRig(settings: settings, shell: shell)
        running = rig
        if settings.wraps {
            // For this launch only (the argument domain), as Settings → Wrap code would.
            // Merged into the launch arguments (replacing the domain dropped `-cmuxMobile.setupComplete`).
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[CmuxMobilePreferences.Key.wrapCode] = true
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        await rig.open(screen)
        try? await Task.sleep(for: .seconds(settings.settle))
        guard settings.passes > 0 else {
            // A still: hold the screen (optionally panned) for a screenshot.
            if let x = settings.holdX, let scroll = rig.findScrollView(horizontal: true) {
                scroll.contentOffset.x = min(CGFloat(x), max(0, scroll.contentSize.width - scroll.bounds.width))
            }
            // `CMUX_MOBILE_LIST_HOLD_Y=F`: rest at fraction F of the list's height (1 is the bottom).
            if let fraction = settings.holdY, let scroll = rig.findScrollView(horizontal: false) {
                let top = -scroll.adjustedContentInset.top
                let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.contentOffset.y = top + (bottom - top) * CGFloat(min(max(fraction, 0), 1))
            }
            rig.log.notice("FRAMELOG list-stress holding \(screen, privacy: .public)")
            return
        }
        rig.startLive()
        rig.begin()
    }

    /// The rig in progress, kept until it finishes (between passes no display link holds it).
    private static var running: ListStressRig?

    // MARK: Seeding and navigation

    private func open(_ screen: String) async {
        let store = shell.store
        switch screen {
        case "workspaces":
            store.workspaces = Self.workspaces(count: settings.count, from: store.workspaces)
            shell.tab = .workspaces
        case "tabs":
            guard var ws = store.workspace(id: "ws-cmux") else { return }
            ws.tabs = Self.tabs(count: settings.count)
            ws.activeTabID = "t-g0"
            store.workspaces = store.workspaces.map { $0.id == ws.id ? ws : $0 }
            store.noteOpened(tabID: "t-g0", in: ws.id)
            shell.tab = .workspaces
            try? await Task.sleep(for: .seconds(1))
            // Opening the workspace from the list (the push and its first page).
            FrameIntervalLog.shared.begin("tabs-push")
            shell.workspacesPath = [ws]
            try? await Task.sleep(for: .seconds(2))
            FrameIntervalLog.shared.end()
            if settings.streams { DemoDirector.shared.post(.chatSend("stream")) }
            try? await Task.sleep(for: .seconds(1))
            if settings.streams {
                // The prompt is typed into t-g0's composer, then sent: say whether its turn runs.
                try? await Task.sleep(for: .seconds(1))
                let chat = AgentSessionDirectory.shared.existingStore(id: "t-g0", macID: ws.macID)
                log.notice("FRAMELOG list-stress tabs stream running=\(chat?.isRunning ?? false, privacy: .public) turns=\(chat?.turns.count ?? -1, privacy: .public)")
            }
            FrameIntervalLog.shared.begin("tabs-open-grid")
            WorkspaceDemoDirector.shared.post(.showGrid(true))
            try? await Task.sleep(for: .seconds(2))
            FrameIntervalLog.shared.end()
        case "chat", "diff", "artifacts":
            guard let ws = store.workspace(id: "ws-cmux") else { return }
            store.noteOpened(tabID: "t-codex-stress", in: ws.id)
            var opened = ws
            // Codex: no waiting question on open, so the transcript is the replayed history.
            opened.tabs.insert(WorkspaceTab(id: "t-codex-stress", kind: .agent, title: "Codex", subtitle: "Stress transcript",
                                            harness: "codex"), at: 0)
            store.workspaces = store.workspaces.map { $0.id == ws.id ? opened : $0 }
            shell.tab = .workspaces
            try? await Task.sleep(for: .seconds(settings.openDelay))
            FrameIntervalLog.shared.begin("\(screen)-open")
            shell.workspacesPath = [opened]
            try? await Task.sleep(for: .seconds(2.5))
            // A main thread blocked past the window resumes here first: let the display link log
            // that long frame before the window closes (it was dropped, so a stalled open read as 0).
            try? await Task.sleep(for: .milliseconds(100))
            FrameIntervalLog.shared.end()
            logMemory("\(screen)-opened")
            if screen == "diff" {
                FrameIntervalLog.shared.begin("diff-open")
                DemoDirector.shared.post(.chatOpenFirstFile)
                try? await Task.sleep(for: .seconds(3))
                FrameIntervalLog.shared.end()
                if settings.splits {
                    FrameIntervalLog.shared.begin("diff-open-split")
                    DemoDirector.shared.post(.diffSetSplit(true))
                    try? await Task.sleep(for: .seconds(2))
                    FrameIntervalLog.shared.end()
                }
                logMemory("diff-file-opened")
            } else if screen == "artifacts" {
                FrameIntervalLog.shared.begin("artifacts-open")
                DemoDirector.shared.post(.chatOpenArtifacts)
                try? await Task.sleep(for: .seconds(2))
                FrameIntervalLog.shared.end()
                // The grid: every tile makes its thumbnail (image decode, PDF page, HTML snapshot).
                FrameIntervalLog.shared.begin("artifacts-open-grid")
                DemoDirector.shared.post(.artifactsLayout(grid: true))
                try? await Task.sleep(for: .seconds(3))
                FrameIntervalLog.shared.end()
                logMemory("artifacts-grid")
            } else {
                if settings.sends {
                    // Typed into the composer (28 ms a character), then sent.
                    let prompt = "Make the dialer retry with backoff"
                    DemoDirector.shared.post(.chatSend(prompt))
                    try? await Task.sleep(for: .seconds(Double(prompt.count) * 0.028 + 2.5))
                } else if settings.streams {
                    DemoDirector.shared.post(.chatSend("stream"))
                }
                try? await Task.sleep(for: .seconds(1))
                // As a reader does: leave the newest turn (the transcript stops following it).
                DemoDirector.shared.post(.chatScroll(toTop: true))
            }
        case "feed":
            // The Feed's own seeding (`CMUX_MOBILE_FEED_STRESS=N`); this rig only scrolls, as a reference.
            shell.tab = .feed
        case "home":
            MacHomeFeed.shared.seedStressRows(count: settings.count, macID: "mac-studio")
            shell.tab = .home
        default:
            log.error("FRAMELOG list-stress unknown screen \(screen, privacy: .public)")
        }
    }

    /// `count` workspaces cycled from the mock ones: a quarter working (the shimmer),
    /// some needing the person, activity spread over two days.
    static func workspaces(count: Int, from templates: [Workspace]) -> [Workspace] {
        guard count > 0, !templates.isEmpty else { return templates }
        let now = Date()
        return (0..<count).map { index in
            let template = templates[index % templates.count]
            let working = index % 4 == 1
            let needsYou = index % 9 == 0
            let tabs = template.tabs.enumerated().map { offset, tab in
                WorkspaceTab(id: "t-s\(index)-\(offset)", kind: tab.kind, title: tab.title, subtitle: tab.subtitle, harness: tab.harness,
                             url: tab.url, agentStatus: tab.kind == .agent ? (working ? .working : (needsYou ? .waiting : nil)) : nil)
            }
            return Workspace(
                id: "ws-s\(index)", macID: index % 5 == 4 ? "mbp" : "mac-studio", title: "\(template.title) \(index)",
                directory: template.directory, branch: template.branch, tabs: tabs,
                lastActivityAt: now.addingTimeInterval(-Double(index) * 600), needsAttention: needsYou, isWorking: working,
                hasUnread: index % 3 == 0, colorHex: template.colorHex, icon: template.icon
            )
        }
    }

    /// `count` tabs: agents, terminals and browsers in turn.
    static func tabs(count: Int) -> [WorkspaceTab] {
        (0..<max(count, 1)).map { index in
            switch index % 3 {
            case 0: WorkspaceTab(id: "t-g\(index)", kind: .agent, title: "Claude \(index)", subtitle: "Refactor the dialer", harness: "claude")
            case 1: WorkspaceTab(id: "t-g\(index)", kind: .terminal, title: "zsh \(index)", subtitle: "~/Development/cmux")
            default: WorkspaceTab(id: "t-g\(index)", kind: .browser, title: "Docs \(index)", subtitle: "developer.apple.com",
                                  url: URL(string: "https://developer.apple.com/documentation/swiftui"))
            }
        }
    }

    // MARK: Live changes

    /// What a busy Mac publishes: one workspace's activity and working state change,
    /// and the whole list is replaced (as `AppStore.replaceWorkspaces` does), `liveHz` times a second.
    private func startLive() {
        guard let hz = settings.liveHz, hz > 0 else { return }
        let store = shell.store
        live = Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / hz))
                tick += 1
                var next = store.workspaces
                guard !next.isEmpty else { continue }
                let index = (tick * 7) % next.count
                next[index].lastActivityAt = Date()
                next[index].isWorking.toggle()
                store.workspaces = next
            }
        }
    }

    // MARK: Scrolling

    /// The visible scroll view with the most content past the fold (below it, or to the right
    /// when panning), inside the topmost presented screen (a sheet over the chat).
    func findScrollView(horizontal: Bool? = nil) -> UIScrollView? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        let root: UIView = top?.view ?? window
        let horizontal = horizontal ?? self.horizontal
        var best: (view: UIScrollView, overflow: CGFloat)?
        func visible(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let node = current {
                if node.isHidden || node.alpha < 0.01 { return false }
                current = node.superview
            }
            return true
        }
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.bounds.height > 200, visible(scroll) {
                let frame = scroll.convert(scroll.bounds, to: window)
                // The tab grid fills the screen; the active chat drawn live on its card
                // (scaled down) has a longer transcript and is not the list measured.
                if settings.screen == "tabs", frame.height < window.bounds.height * 0.8 { view.subviews.forEach(walk); return }
                let overflow = horizontal ? scroll.contentSize.width - scroll.bounds.width : scroll.contentSize.height - scroll.bounds.height
                if frame.intersects(window.bounds), overflow > 100, overflow > (best?.overflow ?? 0) { best = (scroll, overflow) }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return best?.view
    }

    private func begin() {
        guard let scroll = findScrollView() else {
            log.error("FRAMELOG list-stress no scroll view for \(self.settings.screen ?? "-", privacy: .public)")
            finish()
            return
        }
        scrollView = scroll
        // A transcript opens at its bottom: its first pass goes up.
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        if !horizontal, scroll.contentOffset.y >= bottom - 4 { direction = -1 }
        log.notice("FRAMELOG list-stress \(self.settings.screen ?? "-", privacy: .public) scroll=\(String(describing: type(of: scroll)), privacy: .public) content=\(Int(scroll.contentSize.height), privacy: .public)x\(Int(scroll.contentSize.width), privacy: .public)")
        startPass()
    }

    private func startPass() {
        let name = horizontal ? (direction > 0 ? "right" : "left") : (direction > 0 ? "down" : "up")
        FrameIntervalLog.shared.begin("\(settings.screen ?? "list")-\(name)-\(pass)")
        last = nil
        passStart = nil
        placed = nil
        fights = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { link.invalidate(); finish(); return }
        let dt = last.map { link.timestamp - $0 } ?? 0
        last = link.timestamp
        if passStart == nil { passStart = link.timestamp }
        let current = horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
        if let placed, abs(current - placed) > 1 { fights += 1 }
        let inset = scrollView.adjustedContentInset
        let top = horizontal ? -inset.left : -inset.top
        let bottom = horizontal
            ? max(top, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
            : max(top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        // A pass that starts at the bottom leaves it in one step past the transcript's
        // 80 pt follow zone, or the transcript takes the offset back to its newest turn.
        let step = dt == 0 && direction < 0 && !horizontal ? 100 : CGFloat(settings.speed * dt)
        var y = current + direction * step
        let reachedEnd = direction > 0 ? y >= bottom : y <= top
        y = min(max(y, top), bottom)
        if horizontal { scrollView.contentOffset.x = y } else { scrollView.contentOffset.y = y }
        placed = y
        let timedOut = link.timestamp - (passStart ?? link.timestamp) > 90
        guard reachedEnd || timedOut else { return }
        link.invalidate()
        self.link = nil
        FrameIntervalLog.shared.end()
        if fights > 0 || timedOut {
            log.notice("FRAMELOG list-stress pass \(self.pass, privacy: .public) moved-by-list=\(self.fights, privacy: .public) timed-out=\(timedOut, privacy: .public) y=\(Int(y), privacy: .public)")
        }
        if settings.screen == "chat" {
            // Down passes only: at its bottom the transcript follows its newest turn again, and only a
            // drag or the jump command stops that. Jump to the top (as the app's own command does) and go again.
            pass += 1
            guard pass < settings.passes else { finish(); return }
            DemoDirector.shared.post(.chatScroll(toTop: true))
            // From the top, the next pass goes down (the first went up from the bottom).
            direction = 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.startPass()
            }
            return
        }
        if direction < 0 { pass += 1 }
        direction = -direction
        if pass >= settings.passes { finish() } else { startPass() }
    }

    /// Resident memory (phys_footprint), as Xcode's memory gauge shows it.
    private func logMemory(_ label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        log.notice("FRAMELOG list-stress memory \(label, privacy: .public) footprint=\(info.phys_footprint / 1_048_576, privacy: .public)MB")
    }

    private func finish() {
        logMemory("\(settings.screen ?? "-")-done")
        live?.cancel()
        Self.running = nil
        log.notice("FRAMELOG list-stress-done \(self.settings.screen ?? "-", privacy: .public) passes=\(self.pass, privacy: .public)")
        if settings.exitsWhenDone {
            FrameLogFile.flush()
            exit(0)
        }
    }
}
#endif
