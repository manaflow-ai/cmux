public import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// One WebKit tab made at an idle moment before a new tab needs it, so a new WebKit tab's
/// `WKWebView`, its container and its script handlers are not built on the input's turn.
/// Building them held the main thread 29-34 ms per new tab (`switch.content` in
/// `cef-tab-bench.py`'s `webkit_new` and `webkit_url`, light, fleet step d5608a55), two to four
/// frames at 120 Hz, before the tab's page could start loading.
///
/// Chrome keeps a spare renderer for the next navigation (`RenderProcessHostImpl`'s spare
/// RenderProcessHost) and Chrome on Android a spare WebContents outside the tab model
/// (`WarmupManager`); WebKit already prewarms the next web content process itself, so the part
/// left on cmux's main thread is the view, and that is what is made ahead here. The spare holds
/// no page: no navigation ran in it, it has no web content process of its own yet, no history
/// entry and no document, so a take is exactly a fresh tab with another id. It is the default
/// profile's (incognito, other profiles, page-opened windows and machine stores make their tab
/// the ordinary way).
///
/// At most one waits. It is made only once a WebKit tab was made in this process (`noteLikely`;
/// someone who only uses Chromium never pays for it), at an idle moment (no input to the
/// app for `Policy.idleInput` and no menu tracking, waited for with one-shot deadlines; nothing
/// polls), and each take asks for the next one the same way. A memory pressure warning drops it
/// and makes none until pressure is normal again (Chrome's Memory Saver drops spare renderers first).
@MainActor
public final class WebKitSpareTab {
    public struct Policy: Sendable {
        public var idleInput: Duration = .milliseconds(750)

        public init() {}
    }

    /// Debug Settings > Browser Page Loading > "Make new WebKit tabs ahead" (`BrowserPageTunables.all`).
    /// Off: every WebKit tab builds its view when it opens, and a spare left waiting closes.
    nonisolated static let setting = Tunable<Bool>.toggle(
        "browserPage.webKitSpareTab", BrowserPageTunables.section, "Make new WebKit tabs ahead",
        help: "One empty WebKit tab is made ahead at an idle moment, holding no page, and the next new WebKit tab you open takes it instead of building its view when it opens. A new one is made at the next idle moment after each take, and none is kept under memory pressure.",
        default: true, code: "WebKitSpareTab.setting")

    private let policy: Policy
    private let timer: DemandTimer
    private let activity: () -> UInt64
    private let isTrackingMenu: () -> Bool
    private let isEnabled: () -> Bool
    private var activityMark: UInt64 = 0
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?
    private var underPressure = false
    /// Makes the spare (the engine's ordinary tab, with an id no tab has); nil until the engine sets it,
    /// or once the engine is gone.
    var make: (() -> WebKitTab?)?
    /// The waiting spare, at most one.
    public private(set) var tab: WebKitTab?
    /// Whether a WebKit tab is likely soon (`noteLikely`): no spare is made before.
    public private(set) var isLikely = false
    /// Spares a new tab took in this process (`debug` reports).
    public private(set) var taken = 0

    public init(policy: Policy = Policy(), clock: any Clock<Duration> = ContinuousClock(),
                activity: @escaping () -> UInt64 = { ExpectedActivity.shared.total },
                isTrackingMenu: @escaping () -> Bool = { RunLoop.main.currentMode == .eventTracking },
                isEnabled: @escaping () -> Bool = { WebKitSpareTab.setting.value },
                memoryPressure: MemoryPressureEvents? = nil) {
        self.policy = policy
        self.activity = activity
        self.isTrackingMenu = isTrackingMenu
        self.isEnabled = isEnabled
        timer = DemandTimer(owner: "WebKitSpareTab.build", clock: clock)
        if let memoryPressure { watch(memoryPressure) }
    }

    /// `waiting`, `scheduled` or `none`.
    public var state: String { tab != nil ? "waiting" : timer.isScheduled ? "scheduled" : "none" }

    /// The app's memory pressure events (`AppServices.memoryPressure`, through `TabContentCache`): a
    /// warning or critical level drops the spare, and none is made until the level is normal again.
    func watch(_ memoryPressure: MemoryPressureEvents) {
        pressureObservation = memoryPressure.observe { [weak self] level in
            guard let self else { return }
            underPressure = level != .normal
            if underPressure { drop() } else { scheduleBuild() }
        }
    }

    /// A WebKit tab is likely soon: the next idle moment makes the spare.
    public func noteLikely() {
        isLikely = true
        scheduleBuild()
    }

    /// The waiting spare, which is the caller's from now on, or nil (none ready, or switched off).
    /// Either way the next idle moment makes the next one.
    func take() -> WebKitTab? {
        guard isEnabled() else {
            drop()
            return nil
        }
        isLikely = true
        defer { scheduleBuild() }
        guard let tab else { return nil }
        self.tab = nil
        taken += 1
        return tab
    }

    /// Closes the waiting spare, if any, and stops waiting for an idle moment.
    public func drop() {
        timer.cancel()
        tab?.close()
        tab = nil
    }

    private var shouldBuild: Bool { isLikely && tab == nil && !underPressure && make != nil && isEnabled() }

    private func scheduleBuild() {
        guard shouldBuild else { return }
        activityMark = activity()
        timer.schedule(after: policy.idleInput) { @MainActor [weak self] in
            self?.idleDeadline()
        }
    }

    private func idleDeadline() {
        guard shouldBuild, let make else { return }
        guard !isTrackingMenu(), activity() == activityMark else { return scheduleBuild() }
        tab = make()
    }
}
