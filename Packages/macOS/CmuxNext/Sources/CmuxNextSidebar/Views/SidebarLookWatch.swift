import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// A sidebar view that draws a Debug Settings look (``SidebarLook``): it reads the look's tunables
/// when it draws or lays out, and marks itself for that pass when the sidebar's look watch applies
/// a change.
protocol SidebarLookFollower: AnyObject {
    /// A look this view draws may have changed: mark what reads it (display, layout) as needed.
    func sidebarLookChanged()
}

/// Every Debug Settings look a sidebar view draws: the unread badge and Notifications glyph, the
/// group headers and lines, and the workspace rows' tunables (``SidebarTunablesWatch``).
struct SidebarLook: Equatable {
    var badge: NotificationBadgeLook
    var notificationIcon: NotificationIconLook
    var groupHeader: SidebarGroupHeaderStyle
    var groupPalette: SidebarGroupPalette
    var groupLineLayout: SidebarGroupLineLayout
    var agentMark: SidebarAgentMarkVariant
    var presenceDots: Bool
    var rowBadge: SidebarRowBadgeStyle
    var stackCap: SidebarRowBadgeStackCap
    var workspaceTitleMotion: SidebarWorkspaceTitleMotionVariant
    var quietUnnamedRows: Bool
    var rowTitle: SidebarRowTitleMode
    var rowTitleSingleChat: Bool
    /// The listed tab rows' look (`sidebar.tabLines`).
    var tabLines: SidebarTabLineLook
    /// The hover close's spot and glyph size (`sidebar.rowCloseSpot`): laid out, not configured.
    var rowCloseSpot: SidebarRowCloseSpot

    /// The looks now.
    init() {
        badge = NotificationBadgeLook.tunable.value
        notificationIcon = NotificationIconLook.tunable.value
        groupHeader = SidebarGroupHeaderStyle.tunable.value
        groupPalette = SidebarGroupPalette.tunable.value
        groupLineLayout = SidebarGroupLineLayout.tunable.value
        agentMark = SidebarTunables.agentMark.value
        presenceDots = SidebarTunables.presenceDots.value
        rowBadge = SidebarRowBadgeStyle.tunable.value
        stackCap = SidebarRowBadgeStackCap.tunable.value
        workspaceTitleMotion = SidebarTunables.workspaceTitleMotion.value
        quietUnnamedRows = SidebarTunables.quietUnnamedRows.value
        rowTitle = SidebarTunables.rowTitle.value
        rowTitleSingleChat = SidebarTunables.rowTitleSingleChat.value
        tabLines = SidebarTunables.tabLines.value
        rowCloseSpot = SidebarTunables.rowCloseSpot.value
    }
}

/// One watch of the sidebar's Debug Settings looks per sidebar, not one per row or badge: a change
/// applies once per frame and tells every ``SidebarLookFollower`` under the sidebar, as Chrome's
/// `Widget::ThemeChanged` reaches each view through `View::PropagateThemeChanged`
/// (ui/views/widget/widget.cc, ui/views/view.cc). A view reads the look itself when it draws, so a
/// row made after the change draws it with no watch of its own.
final class SidebarLookWatch {
    private let observation: FrameObservation<SidebarLook>

    /// Follows the looks for the views under `root`, from now until ``cancel()`` or release.
    init(root: NSView, on work: MainWorkScheduler) {
        // node-free: the sidebar has no VisibilityNode; the apply only marks views for display and
        // layout, which AppKit skips while they are hidden.
        observation = FrameObservation(owner: "Sidebar.looks", delivery: .visible(nil), on: work) {
            SidebarLook()
        } onChange: { [weak root] _ in
            guard let root else { return }
            SidebarTunablesWatch.shared.drop()
            SidebarLookWatch.tell(root)
        }
    }

    /// Stops following the looks.
    func cancel() {
        observation.cancel()
    }

    /// Tells every follower under `view` (itself included), parents first.
    private static func tell(_ view: NSView) {
        (view as? any SidebarLookFollower)?.sidebarLookChanged()
        for child in view.subviews { tell(child) }
    }
}
