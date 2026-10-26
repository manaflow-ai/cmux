// DEBUG and Demo builds only: the list scroll stress rig (verify/listperf/).
#if os(iOS) && DEBUG
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
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
    private var live: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")

    init(settings: ListStressSettings, shell: ShellModel) {
        self.settings = settings
        self.shell = shell
    }

    static func runIfConfigured(shell: ShellModel) async {
        let settings = ListStressSettings.shared
        guard let screen = settings.screen else { return }
        let rig = ListStressRig(settings: settings, shell: shell)
        await rig.open(screen)
        try? await Task.sleep(for: .seconds(settings.settle))
        rig.startLive()
        rig.begin()
        // Kept alive by the display link until the last pass.
    }

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
            shell.workspacesPath = [ws]
            try? await Task.sleep(for: .seconds(2))
            if settings.streams { DemoDirector.shared.post(.chatSend("stream")) }
            try? await Task.sleep(for: .seconds(1))
            WorkspaceDemoDirector.shared.post(.showGrid(true))
        case "chat", "diff":
            guard let ws = store.workspace(id: "ws-cmux") else { return }
            store.noteOpened(tabID: "t-codex-stress", in: ws.id)
            var opened = ws
            // Codex: no waiting question on open, so the transcript is the replayed history.
            opened.tabs.insert(WorkspaceTab(id: "t-codex-stress", kind: .agent, title: "Codex", subtitle: "Stress transcript",
                                            harness: "codex"), at: 0)
            store.workspaces = store.workspaces.map { $0.id == ws.id ? opened : $0 }
            shell.tab = .workspaces
            try? await Task.sleep(for: .seconds(1))
            shell.workspacesPath = [opened]
            try? await Task.sleep(for: .seconds(2.5))
            if screen == "diff" {
                DemoDirector.shared.post(.chatOpenFirstFile)
            } else if settings.streams {
                DemoDirector.shared.post(.chatSend("stream"))
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

    /// The visible vertical scroll view with the most content below the fold.
    private func findScrollView() -> UIScrollView? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window else { return nil }
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
                let overflow = scroll.contentSize.height - scroll.bounds.height
                if frame.intersects(window.bounds), overflow > 100, overflow > (best?.overflow ?? 0) { best = (scroll, overflow) }
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return best?.view
    }

    private func begin() {
        guard let scroll = findScrollView() else {
            log.error("FRAMELOG list-stress no scroll view for \(self.settings.screen ?? "-", privacy: .public)")
            finish()
            return
        }
        scrollView = scroll
        log.notice("FRAMELOG list-stress \(self.settings.screen ?? "-", privacy: .public) scroll=\(String(describing: type(of: scroll)), privacy: .public) content=\(Int(scroll.contentSize.height), privacy: .public)")
        startPass()
    }

    private func startPass() {
        FrameIntervalLog.shared.begin("\(settings.screen ?? "list")-\(direction > 0 ? "down" : "up")-\(pass)")
        last = nil
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { link.invalidate(); finish(); return }
        let dt = last.map { link.timestamp - $0 } ?? 0
        last = link.timestamp
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        var y = scrollView.contentOffset.y + direction * CGFloat(settings.speed * dt)
        let reachedEnd = direction > 0 ? y >= bottom : y <= top
        y = min(max(y, top), bottom)
        scrollView.contentOffset.y = y
        guard reachedEnd else { return }
        link.invalidate()
        self.link = nil
        FrameIntervalLog.shared.end()
        if direction < 0 { pass += 1 }
        direction = -direction
        if pass >= settings.passes { finish() } else { startPass() }
    }

    private func finish() {
        live?.cancel()
        log.notice("FRAMELOG list-stress-done \(self.settings.screen ?? "-", privacy: .public) passes=\(self.pass, privacy: .public)")
        if settings.exitsWhenDone {
            FrameLogFile.flush()
            exit(0)
        }
    }
}
#endif
