#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

/// What a terminal tab's page needs to know from the tabs chrome.
public struct TerminalTabContext {
    /// Status bar (top) and tab toolbar (bottom) over the page.
    public var safeAreaInsets: EdgeInsets
    /// Where the chrome's cover ends this frame (`TabsKitContentContext.chromeInsets.top`):
    /// above `safeAreaInsets.top` while a top bar is collapsed. The status scrim follows it;
    /// the grid keeps `safeAreaInsets` so its rows never change with the bar. Nil: the same.
    public var chromeTop: CGFloat?
    /// The page is settled full screen and takes input.
    public var isInteractive: Bool
    /// The page is full screen (not zoomed out to the tab grid), even while a menu, a swipe or the
    /// address bar briefly takes input from it: what the page's orientation follows.
    public var isOnPage: Bool
    /// A pinch is driving the tab zoom: suspend the terminal's own pinch.
    public var isZoomGestureActive: Bool
    /// Finger travel on the page (positive = finger down); collapses and
    /// expands the tab toolbar.
    public var reportScroll: @MainActor (CGFloat) -> Void
    /// A terminal web link that opens on the Mac (one only the Mac reaches, or Open on Mac):
    /// a cmux browser tab beside the terminal, in the same
    /// workspace (the Mac's Cmd-click). Nil where no workspace can open one.
    public var openLink: (@MainActor (URL) -> Void)?

    public init(safeAreaInsets: EdgeInsets, chromeTop: CGFloat? = nil, isInteractive: Bool, isZoomGestureActive: Bool,
                reportScroll: @escaping @MainActor (CGFloat) -> Void, openLink: (@MainActor (URL) -> Void)? = nil,
                isOnPage: Bool? = nil) {
        self.safeAreaInsets = safeAreaInsets
        self.chromeTop = chromeTop
        self.isInteractive = isInteractive
        self.isOnPage = isOnPage ?? isInteractive
        self.isZoomGestureActive = isZoomGestureActive
        self.reportScroll = reportScroll
        self.openLink = openLink
    }
}

/// The seam CmuxMobileTerminal plugs into: a workspace's terminal tabs ask this for
/// their page (laid out at full screen size, drawn under the status bar and
/// the tab toolbar), their grid card, and an optional row above the toolbar
/// (the key bar and composer of SPEC 10.2, riding the keyboard).
@MainActor
public protocol TerminalTabContent: AnyObject {
    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView
    /// The tab's grid card. Read in a card's body: no host, session or
    /// request is made here once `prepareCard` ran for the tab.
    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView
    /// Makes what the tab's card shows (its host, its first screen read),
    /// outside any view update: when the tab is listed and when the grid opens.
    func prepareCard(for tab: WorkspaceTab, in workspace: Workspace)
    func accessory(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView?
    /// The terminal's own actions, shown first in the tab's page menu
    /// (TabsKit owns the toolbar, so this is where the keyboard toggle,
    /// Files and Links, and the control keys live).
    func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction]
    /// The tab grid is about to open with `tab` active: refresh its card.
    func overviewWillAppear(active tab: WorkspaceTab)
    /// The tab grid is about to open: the other terminal cards ask the Mac
    /// for its screen now, so none shows an old saved frame (T-TABS-01).
    func overviewWillAppear(inactive tabs: [WorkspaceTab])
    /// The settled grid shows `tab`'s card (`card(for:)`, its snapshot) in
    /// place of its live page, so the active card shows the page's bottom
    /// like the others (VERIFY-round5 V5-6). True only with a snapshot.
    func showsStaticCard(for tab: WorkspaceTab) -> Bool
    /// The grid became visible (true) or was covered by a page (false).
    /// While visible, cards follow their terminals (full verify D6,
    /// T-TABS-01); `tabs` reads the workspace's terminal tabs as they are now.
    func overviewVisibilityChanged(_ visible: Bool, tabs: @escaping @MainActor () -> [WorkspaceTab])
    /// The grid started or stopped scrolling: no card changes in a scroll frame.
    func overviewScrollingChanged(_ scrolling: Bool)
    /// A new terminal tab or workspace: put the keyboard up on its composer.
    func focusInput(for tab: WorkspaceTab, in workspace: Workspace)
    /// New Tab from Text's `!command`: the command waits in the terminal's composer, typed and
    /// not run (the Mac's `newTab.submit` types it into the new terminal), with the keyboard up.
    func draft(_ text: String, for tab: WorkspaceTab, in workspace: Workspace)
    /// Replaces the title pill's subtitle (the working directory) while the
    /// tab's state matters more, e.g. "Reattaching…" after a slow reattach
    /// (design/terminal P5). Nil keeps the directory. Read during view
    /// updates: must not create a tab's host or write state.
    func statusSubtitle(for tab: WorkspaceTab) -> String?
    /// The app went to the background (false) or came back: the grid's view
    /// still counts as visible in the background, so its refresh stops here.
    func sceneActiveChanged(_ active: Bool)
    /// `handler` hears each terminal the Mac says drew output (its tab id and
    /// Mac; a nil tab: any terminal of that Mac may have, its event stream
    /// started again) while `owner` lives. One handler per owner.
    func observeOutput(_ owner: AnyObject, _ handler: @escaping @MainActor (String?, String) -> Void)
    /// The person leaves `tab` (for the grid or another tab) or the app goes to the background:
    /// `keep` hears the tab's card picture as last drawn, once it is ready, and the source keeps
    /// it as the tab's last-known picture (`TabCardSnapshots`). `fresh`: the page is still on
    /// screen, so it is copied now and composed off the main thread first. `onlyIfChanged`: a
    /// page that drew nothing since its card was taken is not copied again, and `keep` hears that
    /// same picture (which `TabCardSnapshots.put` does not encode again). Nothing for a tab with
    /// no host, nor one whose page never drew the Mac's output.
    func captureCard(for tab: WorkspaceTab, fresh: Bool, onlyIfChanged: Bool, keep: @escaping @MainActor (UIImage) -> Void)
    /// `tab` has a page this launch, so `captureCard` may keep a picture of it (the background's
    /// capture spends its bounded count only on these).
    func hostsCard(for tab: WorkspaceTab) -> Bool
    /// The store the cards read last-known pictures from: the tabs source's own
    /// (`WorkspaceTabsSource.snapshots`), so what it keeps is what the cards read.
    func useCardPictures(_ snapshots: TabCardSnapshots)
}

extension TerminalTabContent {
    public func accessory(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView? { nil }
    public func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] { [] }
    public func prepareCard(for tab: WorkspaceTab, in workspace: Workspace) {}
    public func overviewWillAppear(active tab: WorkspaceTab) {}
    public func overviewWillAppear(inactive tabs: [WorkspaceTab]) {}
    public func showsStaticCard(for tab: WorkspaceTab) -> Bool { false }
    public func overviewVisibilityChanged(_ visible: Bool, tabs: @escaping @MainActor () -> [WorkspaceTab]) {}
    public func overviewScrollingChanged(_ scrolling: Bool) {}
    public func focusInput(for tab: WorkspaceTab, in workspace: Workspace) {}
    public func draft(_ text: String, for tab: WorkspaceTab, in workspace: Workspace) {}
    public func statusSubtitle(for tab: WorkspaceTab) -> String? { nil }
    public func sceneActiveChanged(_ active: Bool) {}
    public func observeOutput(_ owner: AnyObject, _ handler: @escaping @MainActor (String?, String) -> Void) {}
    public func captureCard(for tab: WorkspaceTab, fresh: Bool, onlyIfChanged: Bool, keep: @escaping @MainActor (UIImage) -> Void) {}
    public func hostsCard(for tab: WorkspaceTab) -> Bool { false }
    public func useCardPictures(_ snapshots: TabCardSnapshots) {}
}

/// A page menu row a terminal tab adds.
public struct TerminalTabAction {
    public var title: String
    public var systemImage: String
    public var isEnabled: Bool
    public var isDestructive: Bool
    public var perform: @MainActor () -> Void

    public init(title: String, systemImage: String, isEnabled: Bool = true, isDestructive: Bool = false,
                perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.perform = perform
    }
}

/// The default when no terminal content is wired (previews and tests; the
/// shell passes the Ghostty content). It says so instead of drawing a fake
/// shell.
public final class PlaceholderTerminalTabContent: TerminalTabContent {
    let reload: (@MainActor (Workspace) async -> Void)?

    public init(reload: (@MainActor (Workspace) async -> Void)? = nil) { self.reload = reload }

    func retry(_ workspace: Workspace) async { await reload?(workspace) }

    public func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        var retryAction: (@MainActor () async -> Void)?
        if reload != nil {
            retryAction = { [weak self] in
                guard let self else { return }
                await self.retry(workspace)
            }
        }
        return AnyView(PlaceholderTerminalPage(tab: tab, insets: context.safeAreaInsets, retry: retryAction)
            .placeholderBound("terminal.page.unavailable", .milliseconds(2000)))
    }

    public func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(PlaceholderTerminalPage(tab: tab, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0))
            .placeholderBound("tabgrid.terminal.unavailable", .milliseconds(1000)))
    }
}

struct PlaceholderTerminalPage: View {
    let tab: WorkspaceTab
    let insets: EdgeInsets
    var retry: (@MainActor () async -> Void)? = nil
    @State private var autoRetry = AutoRetry()

    var body: some View {
        ContentUnavailableView {
            Label(tab.title, systemImage: "apple.terminal")
        } description: {
            Text("This terminal isn't available.")
        } actions: {
            // Reloads on its own (AutoRetry); past the quiet bound one quiet line, no button.
            AutoRetryQuietLine(autoRetry)
        }
        .autoRetry(autoRetry, failing: retry != nil) { await retry?() }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
#endif
