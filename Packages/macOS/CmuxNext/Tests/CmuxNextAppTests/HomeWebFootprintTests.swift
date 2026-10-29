import CmuxNextLaunch
import Testing

/// Home's web objects once the launch settled (plans/cmux-next/chrome-parity/p13-webui.md D1
/// and D2): the later-tab warm-ups (``LaterTabWarmups``) run on fake engines through the launch's posts, the
/// first frame, the completion and enough frames for every post, and Home then holds only the web objects
/// the default engine uses. Chrome keeps the same rule for its spare renderer: it warms only the process the
/// next navigation takes (content/browser/renderer_host/spare_render_process_host_manager_impl.cc).
@MainActor @Suite(.timeLimit(.minutes(1))) struct HomeWebFootprintTests {
    /// D1: Chromium is the default and agent pages open there. Chromium, its spare window and the New Tab
    /// preload, no WebKit object at all (Settings, History and Cloud preload nothing at launch).
    @Test func chromiumDefaultMakesNoWebKitObject() {
        let engines = HomeWebEngines(defaultEngine: .chromium, agentPages: .chromium)
        settleHome(engines)
        #expect(engines.objects == [.chromiumProcess, .chromiumSpareWindow, .newTabPreload(.chromium)])
        #expect(engines.objects(on: .webKit).isEmpty, "\(engines.objects)")
        #expect(engines.ran == everyLaterTabCall, "each warm-up ran once")
        #expect(engines.marks == ["launch.agent_page_warmup_chromium", "launch.post_window_warmups"])
    }

    /// Chromium is the default and agent chat stays in WebKit (feature `agentChromium` off): WebKit runs only
    /// for agent pages (the warm-up and the New Tab preload), never a Settings page no open asked for.
    @Test func chromiumDefaultWithWebKitAgentPagesWarmsOnlyAgentPages() {
        let engines = HomeWebEngines(defaultEngine: .chromium, agentPages: .webKit)
        settleHome(engines)
        #expect(engines.objects == [.chromiumProcess, .chromiumSpareWindow, .agentWarmup, .newTabPreload(.webKit)])
    }

    /// D2: WebKit is the default. No Chromium object; WebKit holds the agent warm-up and the New Tab preload.
    /// Settings, History and Cloud preload only after an open of their kind (`PagePreloads`), never at launch.
    @Test func webKitDefaultStartsNoChromium() {
        let engines = HomeWebEngines(defaultEngine: .webKit, agentPages: .webKit)
        settleHome(engines)
        #expect(engines.objects(on: .chromium).isEmpty, "\(engines.objects)")
        #expect(engines.objects == [.agentWarmup, .newTabPreload(.webKit)])
        #expect(engines.ran.contains("startPagePreloads"), "the page preloads were not started")
    }

    /// A launch after a crash holds browser pages back: Chromium does not start, whatever the default.
    @Test func crashRecoveryLaunchStartsNoChromium() {
        let engines = HomeWebEngines(defaultEngine: .chromium, agentPages: .webKit, skipsBrowserPages: true)
        settleHome(engines)
        #expect(engines.objects(on: .chromium).isEmpty, "\(engines.objects)")
        #expect(!engines.ran.contains("startChromiumWarmup"))
    }

    /// Before the first frame nothing is made; before startup completes no WebKit object is.
    @Test func noWebObjectBeforeTheFirstFrameAndNoWebKitBeforeCompletion() {
        let engines = HomeWebEngines(defaultEngine: .webKit, agentPages: .webKit)
        let f = LaunchOrderFixture()
        LaterTabWarmups(host: engines).posts().post(on: f.order.startup)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(engines.objects.isEmpty && engines.ran.isEmpty, "nothing runs before the first frame")
        f.order.startup.firstFrameCommitted()
        for _ in 0..<20 { f.fire() }
        #expect(engines.objects(on: .webKit).isEmpty, "WebKit waits for completion")
        #expect(engines.ran == ["startChromiumWarmup", "armNewTabPreload"])
    }
}

/// Every engine call the later-tab warm-ups make, in post order.
private let everyLaterTabCall = ["startChromiumWarmup", "armNewTabPreload", "warmAgentPages", "probeNewTabPreload", "warmNewTabPreload",
                                 "startPagePreloads", "startAgentTabImport", "buildRightSidebarIcons"]

/// The launch, settled: the posts, the first frame, the completion and a frame for every post.
private func settleHome(_ engines: HomeWebEngines) {
    let f = LaunchOrderFixture()
    LaterTabWarmups(host: engines).posts().post(on: f.order.startup)
    f.hand.drain()
    f.order.startup.firstFrameCommitted()
    for _ in 0..<8 { f.fire() }
    f.complete()
    for _ in 0..<32 { f.fire() }
}

/// One web object Home holds.
private enum HomeWebObject: Hashable, CustomStringConvertible {
    enum Engine: Hashable {
        case chromium
        case webKit
    }

    /// Chromium's browser process.
    case chromiumProcess
    /// Chromium's spare window for the next tab (renderer-less where the fork can).
    case chromiumSpareWindow
    /// The agent pages' WebKit warm-up page.
    case agentWarmup
    /// The New Tab page in the app's one preload slot, in the agent pages' engine.
    case newTabPreload(Engine)

    var engine: Engine {
        switch self {
        case .chromiumProcess, .chromiumSpareWindow: .chromium
        case .agentWarmup: .webKit
        case let .newTabPreload(engine): engine
        }
    }

    var description: String {
        switch self {
        case .chromiumProcess: "chromiumProcess"
        case .chromiumSpareWindow: "chromiumSpareWindow"
        case .agentWarmup: "agentWarmup"
        case let .newTabPreload(engine): "newTabPreload(\(engine))"
        }
    }
}

/// Fake engines: each warm-up records the web objects the real one makes for the same settings.
/// `defaultEngine` is `browser.defaultEngine`, which Settings, History and Cloud follow; `agentPages` is
/// where agent pages (and so the New Tab page) open.
private final class HomeWebEngines: LaterTabWarmupHost {
    let defaultEngine: HomeWebObject.Engine
    let agentPages: HomeWebObject.Engine
    let skipsBrowserPagesAtLaunch: Bool
    private(set) var objects: [HomeWebObject] = []
    private(set) var ran: [String] = []
    private(set) var marks: [String] = []

    init(defaultEngine: HomeWebObject.Engine, agentPages: HomeWebObject.Engine, skipsBrowserPages: Bool = false) {
        (self.defaultEngine, self.agentPages, self.skipsBrowserPagesAtLaunch) = (defaultEngine, agentPages, skipsBrowserPages)
    }

    func objects(on engine: HomeWebObject.Engine) -> [HomeWebObject] { objects.filter { $0.engine == engine } }

    /// `ChromiumHostLaunchStart`: Chromium starts at launch when it is the default, with its spare window.
    func startChromiumWarmup() {
        ran.append("startChromiumWarmup")
        guard defaultEngine == .chromium else { return }
        objects += [.chromiumProcess, .chromiumSpareWindow]
    }

    func armNewTabPreload() { ran.append("armNewTabPreload") }

    /// `AgentPageWarmup.start(webUI:)`: a WebKit page only while agent pages open in WebKit; each outcome its mark.
    func warmAgentPages() -> String? {
        ran.append("warmAgentPages")
        guard agentPages == .webKit else { return "launch.agent_page_warmup_chromium" }
        objects.append(.agentWarmup)
        return "launch.agent_page_warmup"
    }

    func probeNewTabPreload() { ran.append("probeNewTabPreload") }

    func warmNewTabPreload() {
        ran.append("warmNewTabPreload")
        objects.append(.newTabPreload(agentPages))
    }

    /// `PagePreloads.start()`: it makes no page until an open of Settings, History or Cloud names one.
    func startPagePreloads() { ran.append("startPagePreloads") }

    func startAgentTabImport() { ran.append("startAgentTabImport") }

    func buildRightSidebarIcons() { ran.append("buildRightSidebarIcons") }

    func markLaunch(_ name: String) { marks.append(name) }
}
