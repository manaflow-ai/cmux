import AppKit
import CmuxNextWakeups

/// One tab's renderer hang under Chrome's visibility rules (feature
/// `chromiumHangFollowsVisibility`).
///
/// Chromium times the hang itself: `RenderWidgetHostImpl` calls a renderer unresponsive when an
/// input event has had no ACK for `kHungRendererDelay`, 15 s on desktop
/// (components/input/input_constants.h), and CEF hands the tab RENDER_UNRESPONSIVE with a callback
/// that `cmux_shim_unresponsive_reply` answers: Wait restarts that timer, Exit page ends the renderer.
/// cmux keeps no timer of its own. Chrome reports a hang only for a visible tab: a hidden one's
/// `WasHidden` stops the timer (`StopInputEventAckTimeout`, which also takes the hang back), its
/// `WasShown` starts it again (`RestartInputEventAckTimeoutIfNecessary`), and a report that comes
/// while the tab is not visible is dropped (`WebContentsImpl::RendererUnresponsive`, crbug.com/881812;
/// content/browser/renderer_host/render_widget_host_impl.cc,
/// content/browser/web_contents/web_contents_impl.cc).
///
/// cmux shows the hang as the tab's own prompt (`PageStatusViews`), never as anything of the
/// Chromium Host's: the host's busy banner times the host's dispatch of
/// cmux's input, which a hung renderer never holds. A hang that comes while the tab is hidden, or
/// a prompt whose tab hides, is held: no prompt, and Chromium's callback stays unanswered. When the
/// tab shows, cmux answers Wait, so the timer runs a full `kHungRendererDelay` again from the show,
/// as Chrome's `WasShown` restarts it. A Chromium that heard the hide (fork API 37,
/// ``CEFTabNodeVisibility``) takes the hang back with RENDER_RESPONSIVE first, and then the show
/// answers nothing.
nonisolated struct CEFRendererHang: Equatable, Sendable {
    /// What the tab does after a step.
    nonisolated enum Step: Equatable, Sendable {
        case nothing
        /// The tab's Page unresponsive prompt shows.
        case prompt
        /// The prompt goes; Chromium's callback stays unanswered.
        case withdraw
        /// Answer Wait: Chromium restarts the hang timer, `kHungRendererDelay` from now.
        case restartTimer
    }

    /// Chromium reported a hang the tab does not show: its callback waits, unanswered, for the tab to show.
    private(set) var isHeld = false

    /// RENDER_UNRESPONSIVE. `shown`: the tab is visible now.
    mutating func reported(shown: Bool) -> Step {
        isHeld = !shown
        return shown ? .prompt : .nothing
    }

    /// RENDER_RESPONSIVE, a renderer exit or an answer: Chromium holds no callback for the tab.
    mutating func ended() {
        isHeld = false
    }

    /// The tab showed or hid. `prompting`: its prompt shows now.
    mutating func shownChanged(shown: Bool, prompting: Bool) -> Step {
        if shown {
            guard isHeld else { return .nothing }
            isHeld = false
            return .restartTimer
        }
        guard prompting else { return .nothing }
        isHeld = true
        return .withdraw
    }
}

/// The window a shown tab watches for the hang rules (``CEFTab/followRendererHangWindow()``): its
/// minimize, its occlusion and its occlusion family's flips.
struct CEFRendererHangWindowWatch {
    weak var window: NSWindow?
    var events: [EventSubscription] = []
    var occlusion: WindowOcclusionSubscription?
}

extension CEFTab {
    /// Chrome's `WebContents::GetVisibility() == Visibility::VISIBLE` for the hang rules: the tab its
    /// pane shows, not hidden by the content lifecycle, in a window that shows (ordered in, not
    /// minimized, its app not hidden) and is not occluded, by AppKit or by its
    /// ``WindowOcclusionFamily``, as `-[WebContentsViewCocoa updateWebContentsVisibility]` makes a
    /// covered window's tabs `OCCLUDED` (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm).
    /// Each change reaches ``rendererHangVisibilityChanged()``: the tab's content view shows or hides
    /// in its pane (`contentDidAppear(in:)`, `contentDidDisappear()`), ``setContentVisible(_:)``, and
    /// the shown tab's window (``followRendererHangWindow()``).
    var showsForRendererHang: Bool {
        guard showsInPaneForRendererHang, let window = container.window else { return false }
        let covered = WindowOcclusionFamily.installed(on: window)?.isOccluded ?? false
        let state = runtime.rendererHangWindows.windowState(window)
        return !covered && ChromiumHostPageVisibility.WindowState.visibility(of: state) == .visible
    }

    /// The tab's part of ``showsForRendererHang``: its pane shows it and the content lifecycle does not hide it.
    private var showsInPaneForRendererHang: Bool { !isClosed && host.visibleTab === self && !isContentHidden }

    /// Answers "Page unresponsive" (``BrowserHangAnswering``) through `cmux_shim_unresponsive_reply`:
    /// wait restarts Chromium's hang timer, terminate ends the renderer (the sad tab follows).
    public func answerUnresponsivePage(terminate: Bool) {
        guard state.isUnresponsive else { return }
        if let browserID { _ = runtime.shim?.unresponsiveReply(browserID, terminate ? 1 : 0) }
        if !terminate { machine.apply(.unresponsiveChanged(false)) }
    }

    /// RENDER_UNRESPONSIVE: the prompt shows, or, with the visibility rules on and the tab hidden, the hang is held.
    func rendererBecameUnresponsive() {
        if runtime.rendererHangFollowsVisibility {
            applyRendererHang(rendererHang.reported(shown: showsForRendererHang))
        } else {
            machine.apply(.unresponsiveChanged(true))
        }
    }

    /// RENDER_RESPONSIVE: the hang is over, shown or held.
    func rendererBecameResponsive() {
        rendererHang.ended()
        machine.apply(.unresponsiveChanged(false))
    }

    /// The tab showed or hid: a held hang restarts Chromium's timer, a prompt on a hidden tab goes.
    func rendererHangVisibilityChanged() {
        guard runtime.rendererHangFollowsVisibility else { return }
        followRendererHangWindow()
        applyRendererHang(rendererHang.shownChanged(shown: showsForRendererHang, prompting: state.isUnresponsive))
    }

    /// Watches the window of the tab its pane shows, and nothing for a hidden tab: a minimize, an
    /// occlusion change (an app hide or unhide changes every window's) or a flip of the window's
    /// ``WindowOcclusionFamily`` reaches ``rendererHangVisibilityChanged()``. The window's notices come
    /// through ``CEFRuntime/rendererHangWindows`` (its shared ``WindowEvents``; a test's own).
    private func followRendererHangWindow() {
        let window = showsInPaneForRendererHang ? container.window : nil
        guard window !== rendererHangWindowWatch.window else { return }
        rendererHangWindowWatch = CEFRendererHangWindowWatch()
        guard let window else { return }
        let events = runtime.rendererHangWindows.events(window)
        let owner = "CEFTab.rendererHang"
        let update: @MainActor () -> Void = { [weak self] in self?.rendererHangVisibilityChanged() }
        rendererHangWindowWatch = CEFRendererHangWindowWatch(
            window: window,
            events: [
                events.subscribe(NSWindow.didMiniaturizeNotification, owner: owner, update),
                events.subscribe(NSWindow.didDeminiaturizeNotification, owner: owner, update),
                events.subscribe(NSWindow.didChangeOcclusionStateNotification, owner: owner, update),
            ],
            occlusion: WindowOcclusionFamily.of(window).subscribe(.content, owner: owner) { [weak self] _ in
                self?.rendererHangVisibilityChanged()
            })
    }

    private func applyRendererHang(_ step: CEFRendererHang.Step) {
        switch step {
        case .nothing: break
        case .prompt: machine.apply(.unresponsiveChanged(true))
        case .withdraw: machine.apply(.unresponsiveChanged(false))
        case .restartTimer:
            // A post in host mode. A callback Chromium already dropped (it heard the hide) restarts nothing.
            if let browserID { _ = runtime.shim?.unresponsiveReply(browserID, 0) }
        }
    }
}

/// `debug.cef` `renderer_hangs`: one Chromium tab's renderer hang as cmux shows it.
public struct CEFRendererHangReport: Equatable, Sendable {
    public let browser: Int32
    public let title: String?
    /// The tab's Page unresponsive prompt shows.
    public let prompting: Bool
    /// A hang waits, held, for the tab to show (``CEFRendererHang/isHeld``).
    public let held: Bool
    /// The tab is visible for the hang rules (``CEFTab/showsForRendererHang``).
    public let shown: Bool
}

extension CEFEngine {
    /// Turns Chrome's visibility rules for renderer hangs on (feature `chromiumHangFollowsVisibility`).
    /// Off: every hang prompts in its tab at once, shown or not, as before.
    public func followingVisibilityForRendererHangs(_ enabled: Bool) -> CEFEngine {
        CEFRuntime.shared.rendererHangFollowsVisibility = enabled
        return self
    }

    /// Every Chromium tab's hang, by browser; nil while the visibility rules are off.
    public var rendererHangs: [CEFRendererHangReport]? {
        let runtime = CEFRuntime.shared
        guard runtime.rendererHangFollowsVisibility else { return nil }
        return runtime.tabsByBrowser.sorted { $0.key < $1.key }.map { browser, tab in
            CEFRendererHangReport(browser: browser, title: tab.state.title, prompting: tab.state.isUnresponsive,
                                  held: tab.rendererHang.isHeld, shown: tab.showsForRendererHang)
        }
    }
}
