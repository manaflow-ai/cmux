import AppKit
import CmuxNextDesign
public import CmuxNextWakeups
import Foundation

/// Why ``CEFEngine/makePagesTab(_:)`` made no page tab.
public nonisolated enum CEFPagesTabError: Error {
    /// The engine made a tab that is not a CEF tab.
    case notChromium
}

/// A cmux page's Chromium tab (`ChromiumPageHost`): every page shares the pages profile (``beginPagesProfile()``).
/// The page tabs of one cmux pane share that pane's page window, keyed apart from any browser pane's
/// window; a page with no pane has a window of its own.
extension CEFEngine {
    /// The configuration of a new cmux page tab: the pages profile, and `pane`'s page window, or a pane of its own
    /// when `pane` is nil. `chatOpen` (the agent chat open the page shows) gets the stages of the window that pane
    /// gets: its create, created and first contentful paint, until that paint or until the window's host leaves the
    /// routing table. A window taken from the spare was made before: only its paint is a stage.
    ///
    /// - Parameters:
    ///   - chatOpen: The open the page shows; nil for any other page.
    ///   - pane: The page window the tab joins (``pagesPane(window:pane:)``); nil gives it its own.
    /// - Returns: The tab's configuration, for ``makePagesTab(_:)``.
    public func pagesTabConfiguration(chatOpen: ChatOpenStages?, pane shared: BrowserPaneID? = nil) -> BrowserTabConfiguration {
        let pane = shared ?? BrowserPaneID(rawValue: "cmux-page-" + UUID().uuidString)
        if let chatOpen { CEFRuntime.shared.chatOpens[pane.rawValue] = chatOpen }
        return BrowserTabConfiguration(profile: beginPagesProfile(), pane: pane, origin: .user)
    }

    /// The page window of pane `pane` of main window `window`: one Chromium window holds that pane's page tabs, as
    /// one Chrome `Browser` holds its tab strip (chrome/browser/ui/browser.h). Never a browser pane's key.
    ///
    /// - Parameters:
    ///   - window: The main window's id.
    ///   - pane: The pane's key.
    /// - Returns: The pane key of the page window.
    public nonisolated static func pagesPane(window: String, pane: String) -> BrowserPaneID {
        BrowserPaneID(rawValue: "cmux-page-pane-\(window)/\(pane)")
    }

    /// Makes the page tab `configuration` describes (``pagesTabConfiguration(chatOpen:pane:)``), themed as an internal page.
    ///
    /// - Parameter configuration: The page tab's configuration.
    /// - Returns: The tab.
    /// - Throws: ``CEFPagesTabError`` when the tab is not a CEF tab, or the engine's error when Chromium cannot start.
    public func makePagesTab(_ configuration: BrowserTabConfiguration) async throws -> CEFTab {
        let made = try await makeTab(configuration)
        guard let tab = made as? CEFTab else {
            made.close()
            throw CEFPagesTabError.notChromium
        }
        tab.pageThemeSurface = .internalPage
        tab.agentRelay.servesCmuxPage = true
        return tab
    }

    /// Starts Chromium again for the page tabs whose browsers the Chromium Host took with it
    /// (``CEFRuntime/hostEnded(_:)``): the supervisor starts a new host, or refuses one that ended
    /// again soon after its start, as a sad tab's Reload asks it (``CEFRuntime/reloadAfterHostRestart(_:)``).
    /// Every page of that end asks in the end's turn; the shared attach (`CEFHostStart`) makes one
    /// start for all of them.
    ///
    /// - Parameter done: Gets true once a new host is attached; false, in the call, in process (a
    ///   browser that ended there cannot start again) and when only the page's browser ended; false
    ///   when no new host starts.
    public func restartPagesAfterHostEnd(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard CEFRuntime.shared.awaitsHostRestart else { return done(false) }
        Self.restartHost(self, then: done)
    }

    /// The start waits off the main actor, as a sad tab's Reload does: it runs on main as the engine's
    /// own call, and the main thread holds nothing while the supervisor starts the host.
    private nonisolated static func restartHost(_ engine: CEFEngine, then done: @escaping @MainActor @Sendable (Bool) -> Void) {
        // task-owner: one per page whose browser the host took; the shared attach (CEFHostStart) owns the restart, and quit fails it
        Task { [weak engine] in
            guard let engine else { return await done(false) }
            do { try await engine.startRuntime(trigger: "hostRestart") } catch { return await done(false) }
            await done(true)
        }
    }
}

extension CEFTab {
    /// Moves this page tab into pane `pane`'s page window (``CEFEngine/pagesPane(window:pane:)``), same profile and
    /// store, document and history kept: `cmux_tab_move_to_window`, as Chrome moves a dragged tab between tab strips
    /// with its `WebContents` (chrome/browser/ui/tabs/tab_strip_model.cc, `DetachWebContentsAtForInsertion`, then
    /// `InsertWebContentsAt`). The tab joins the pane's host now and moves into its Chromium window the way a popup
    /// moves into its own (`CEFPaneHost.movePopupsIn`): into a live window on the next turn; a shown tab whose pane
    /// has no window yet gets one after this turn's frame commits, a hidden one when it shows. The host it left
    /// goes once empty (`CEFRuntime.hostEmptied`).
    ///
    /// - Parameter pane: The page window's pane.
    /// - Returns: True when the tab is in, or on its way into, `pane`'s window; false when it cannot move (closed, no
    ///   browser yet, a popup, or a fork without the move), and it stays where it is. A tab still on its way may move
    ///   again; one moved back to the window that holds it moves nothing in Chromium.
    @discardableResult
    public func moveToPagesPane(_ pane: BrowserPaneID) -> Bool { runtime.move(self, toPane: pane) }
}

extension CEFRuntime {
    /// ``CEFTab/moveToPagesPane(_:)``.
    func move(_ tab: CEFTab, toPane pane: BrowserPaneID) -> Bool {
        let from = tab.host
        if from.key.pane == pane { return true }
        guard !tab.isClosed, let shim, let browser = tab.browserID, !from.isPopupHost,
              forkAPIVersion >= CEFPaneHost.tabMoveForkAPI else { return false }
        let key = CEFPaneKey(pane: pane, profile: from.key.profile, machineKey: from.key.machineKey, offTheRecord: from.key.offTheRecord)
        let to = host(for: key, lifecycleTrace: from.lifecycleTrace, contextMenus: from.contextMenus)
        let container = tab.container
        // The tab's pane shows it: its content view presented it (`CEFTabContentView`) and no hide followed.
        let shown = from.visibleTab === tab
        // Back in the window that still holds it (moved away and back before it showed there): nothing moves.
        let staysInWindow = to.isLive && to.owns(window: shim.tabWindowID(browser))
        from.conceal(tab)
        if from.hostView.superview === container { from.hostView.removeFromSuperview() }
        tab.host = to
        tab.awaitsWindowMove = !staysInWindow
        // The window it leaves shows that host's own tab again once it left (`movePopupsIn`).
        tab.popupOpenerHost = staysInWindow ? nil : from
        to.add(tab)
        from.removed(tab)
        if shown {
            // A live window takes it on the next turn; a pane with none builds one after the frame commits (`present`).
            to.present(tab, in: container)
        } else if to.isLive, !staysInWindow {
            to.ensureOwnWindow(for: tab)
        }
        // A hidden tab whose pane has no window gets one when it shows (`CEFTabContentView` presents it).
        return true
    }

    /// Writes `stage` for the chat open whose page's window is `pane`'s (``CEFEngine/pagesTabConfiguration(chatOpen:pane:)``):
    /// one dictionary read per window step when none is. The first contentful paint is the last.
    func chatStage(_ stage: ChatOpenStage, pane: String) {
        guard let chatOpen = chatOpens[pane] else { return }
        if stage == .firstContentfulPaint { chatOpens[pane] = nil }
        chatOpen.mark(stage)
    }
}
