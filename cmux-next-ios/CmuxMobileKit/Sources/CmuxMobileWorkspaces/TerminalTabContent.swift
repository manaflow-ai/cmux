#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// What a terminal tab's page needs to know from the tabs chrome.
public struct TerminalTabContext {
    /// Status bar (top) and tab toolbar (bottom) over the page.
    public var safeAreaInsets: EdgeInsets
    /// The page is settled full screen and takes input.
    public var isInteractive: Bool
    /// A pinch is driving the tab zoom: suspend the terminal's own pinch.
    public var isZoomGestureActive: Bool
    /// Finger travel on the page (positive = finger down); collapses and
    /// expands the tab toolbar.
    public var reportScroll: @MainActor (CGFloat) -> Void
    /// A web link tapped in the terminal: a cmux browser tab beside it, in the same
    /// workspace (the Mac's Cmd-click). Nil where no workspace can open one.
    public var openLink: (@MainActor (URL) -> Void)?

    public init(safeAreaInsets: EdgeInsets, isInteractive: Bool, isZoomGestureActive: Bool,
                reportScroll: @escaping @MainActor (CGFloat) -> Void, openLink: (@MainActor (URL) -> Void)? = nil) {
        self.safeAreaInsets = safeAreaInsets
        self.isInteractive = isInteractive
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
    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView
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
    /// Replaces the title pill's subtitle (the working directory) while the
    /// tab's state matters more, e.g. "Reattaching…" after a slow reattach
    /// (design/terminal P5). Nil keeps the directory. Read during view
    /// updates: must not create a tab's host or write state.
    func statusSubtitle(for tab: WorkspaceTab) -> String?
}

extension TerminalTabContent {
    public func accessory(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView? { nil }
    public func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] { [] }
    public func overviewWillAppear(active tab: WorkspaceTab) {}
    public func overviewWillAppear(inactive tabs: [WorkspaceTab]) {}
    public func showsStaticCard(for tab: WorkspaceTab) -> Bool { false }
    public func overviewVisibilityChanged(_ visible: Bool, tabs: @escaping @MainActor () -> [WorkspaceTab]) {}
    public func overviewScrollingChanged(_ scrolling: Bool) {}
    public func focusInput(for tab: WorkspaceTab, in workspace: Workspace) {}
    public func statusSubtitle(for tab: WorkspaceTab) -> String? { nil }
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
    public init() {}

    public func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        AnyView(PlaceholderTerminalPage(tab: tab, insets: context.safeAreaInsets))
    }

    public func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(PlaceholderTerminalPage(tab: tab, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0)))
    }
}

struct PlaceholderTerminalPage: View {
    let tab: WorkspaceTab
    let insets: EdgeInsets

    var body: some View {
        ContentUnavailableView {
            Label(tab.title, systemImage: "apple.terminal")
        } description: {
            Text("This terminal isn't available.")
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
#endif
