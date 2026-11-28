import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// goal screen-share-interaction-paths. The feature-flows probe on NIGHTLY 946de8ba (cmux#60945) opens a page from a
/// fresh window whose workspace is Home as a lone pinned dock: the palette's Settings read "selected visible tab page
/// is not 'settings' (selected pages ['home-dock', None, None])" and every Screen Sharing path (cmd+shift+s, palette,
/// File menu, + chevron, CLI) read "AX element was not found ... transcript list found, composer found". The page's
/// tab is made, but the window keeps drawing Home's chat. A page a person opens from Home's lone dock shows in a
/// column beside it, selected, focused and drawn inside the window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PageFromHomesLoneDockShowsTests {
    private static func describe(_ window: WindowController, _ home: WorkspaceModel) -> String {
        let panes = window.workspaceContent?.panes.values.map { pane in
            let frame = pane.view.window == nil ? "unattached" : "\(pane.view.convert(pane.view.bounds, to: nil))"
            let selected = pane.stripModel.selectedID?.rawValue ?? "nil"
            return "\(pane.paneKey) hidden=\(pane.view.isHiddenOrHasHiddenAncestor) frame=\(frame) selected=\(selected)"
        } ?? []
        let columns = home.screens.flatMap(\.columns).map { column in
            let dock = column.dock.map { "\($0.edge.rawValue)/\($0.mode.rawValue)" } ?? "none"
            return "\(column.id) dock=\(dock) width=\(column.width) panes=\(column.layout.paneIDs)"
        }
        let bounds = window.window?.contentView?.bounds ?? .zero
        return "window \(bounds), page \(String(describing: window.state.page)), focused \(window.focusedPane?.paneKey ?? "nil"); "
            + "columns \(columns); panes \(panes)"
    }

    /// `overlay`: Home's dock floats (Settings > Layout > Dock columns: Floating). The strip under an overlay dock is
    /// the whole window wide, so the daemon's neighbour width of 1.0 drew the page a full window wide from the dock's
    /// inner edge, half past the window's right edge (the + chevron row's hover point x=1133.5 in an 1100-wide window).
    @Test(arguments: ["settings", "macScreen.open", "settings overlay", "macScreen.open overlay"])
    func aPageFromHomesLoneDockShowsBesideIt(_ argument: String) async throws {
        let overlay = argument.hasSuffix(" overlay")
        let via = overlay ? String(argument.dropLast(" overlay".count)) : argument
        try await PasswordManagerRouteTests.withApp { services, connection in
            let keyWindow = services.keyWindowSource
            defer { services.keyWindowSource = keyWindow }
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            services.keyWindowSource = { [weak window] in window?.window }
            let dock = try #require(HomeSplitKeysTests.panes(home).first)
            try #require(HomeSplitKeysTests.panes(home).count == 1, "Home is not a lone dock: \(Self.describe(window, home))")
            if overlay {
                let column = try #require(home.screens.flatMap(\.columns).first { $0.dock != nil })
                var floating = try #require(column.dock)
                floating.mode = .overlay
                try await connection.setColumnDock(of: dock.handle, dock: floating)
                try await PasswordManagerRouteTests.until({
                    home.screens.flatMap(\.columns).first { $0.dock != nil }?.dock?.mode == .overlay
                }, report: { "Home's dock did not float: \(Self.describe(window, home))" })
            }
            let page: InternalPageID = via == "settings" ? .settings : .macScreen
            if via == "settings" {
                #expect(services.pages.show(.settings, in: window, focus: true) != nil)
            } else {
                let refusal = services.registry.capturingRefusal {
                    #expect(services.registry.perform("macScreen.open", invocation: ActionInvocation(origin: .user)))
                }
                #expect(refusal == nil, "\(refusal ?? "")")
            }
            @MainActor func shown() -> PaneController? {
                guard let content = window.workspaceContent, let bounds = window.window?.contentView?.bounds else { return nil }
                return content.panes.values.first { pane in
                    guard pane.pane !== dock, pane.view.window === window.window, !pane.view.isHiddenOrHasHiddenAncestor,
                          let selected = pane.stripModel.selectedID?.rawValue, services.pages.page(ofTab: selected) == page
                            || pane.pane.tabs.first(where: { $0.id == selected })?.page == page.rawValue else { return false }
                    let frame = pane.view.convert(pane.view.bounds, to: nil)
                    return frame.width > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame)
                }
            }
            try await PasswordManagerRouteTests.until({ shown() != nil && window.state.page == nil }, report: {
                "\(argument): no pane beside Home's dock draws the \(page.rawValue) page: \(Self.describe(window, home))"
            })
            let pane = try #require(shown())
            try await PasswordManagerRouteTests.until({ window.focusedPane === pane }, report: {
                "\(argument): the page's pane is not focused: \(Self.describe(window, home))"
            })
            // Its own column right of the dock, not a split inside the dock's column.
            let screen = try #require(home.screens.first { $0.panes.contains { $0 === dock } })
            let dockColumn = try #require(screen.columns.first { $0.layout.paneIDs.contains(dock.handle) })
            #expect(!dockColumn.layout.paneIDs.contains(pane.pane.handle), "the page split Home's dock: \(Self.describe(window, home))")
        }
    }
}
