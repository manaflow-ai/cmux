import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// goal screen-share-interaction-paths ("Every path in docs/remote-transport/screen-sharing-path-audit.md and every
/// in-session control merged and read back in Leo's NIGHTLY"). The feature-flows walk leaves the columns of its earlier
/// flows in Home's workspace. Every Screen Sharing path (cmd+shift+s, palette, File menu, + chevron, CLI) then made and
/// selected its tab, but no window drew `macScreen.home`, and the chevron's hover point sat at x=1133.5 in an 1100-wide
/// window. A page tab opens in (or is shown in) the first column beside Home's dock and focuses that pane. The strip
/// follows only a focus change, so when that pane already had the focus while the camera was elsewhere (a column
/// revealed beside a chat that kept its focus, cx-27j7), the page was selected off-screen. A focused page open draws its
/// page inside the window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct PageOpenRevealsItsColumnTests {
    private static func describe(_ window: WindowController, _ home: WorkspaceModel) -> String {
        let panes = window.workspaceContent?.panes.values.map { pane in
            let frame = pane.view.window == nil ? "unattached" : "\(pane.view.convert(pane.view.bounds, to: nil))"
            return "\(pane.paneKey) hidden=\(pane.view.isHiddenOrHasHiddenAncestor) frame=\(frame) selected=\(pane.stripModel.selectedID?.rawValue ?? "nil")"
        } ?? []
        let columns = home.screens.flatMap(\.columns).map { "\($0.id) dock=\($0.dock != nil) width=\($0.width) panes=\($0.layout.paneIDs)" }
        let bounds = window.window?.contentView?.bounds ?? .zero
        return "window \(bounds), page \(String(describing: window.state.page)), focused \(window.focusedPane?.paneKey ?? "nil"); "
            + "columns \(columns); panes \(panes)"
    }

    /// `pane` is drawn wholly inside its window.
    private static func onScreen(_ pane: PaneController, in window: WindowController) -> Bool {
        guard pane.view.window === window.window, !pane.view.isHiddenOrHasHiddenAncestor,
              let bounds = window.window?.contentView?.bounds else { return false }
        let frame = pane.view.convert(pane.view.bounds, to: nil)
        return frame.width > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame)
    }

    /// `focus`: where the focus is before the open. `page`: the first column beside the dock, the pane the page opens
    /// in, already focused while the camera shows the last column (the walk's state); `dock`: Home's dock.
    /// Settings goes through `pages.show` (palette, cmd+,); Mac Screen through `macScreen.open` (cmd+shift+s, palette,
    /// File menu, chevron and `cmux mac-screen` all run that action).
    @Test(arguments: ["settings page", "macScreen.open page", "settings dock", "macScreen.open dock", "settings again"])
    func aFocusedPageOpenDrawsItsPageInTheWindow(_ argument: String) async throws {
        let parts = argument.split(separator: " ").map(String.init)
        let via = parts[0], from = parts[1]
        try await PasswordManagerRouteTests.withApp { services, connection in
            let keyWindow = services.keyWindowSource
            defer { services.keyWindowSource = keyWindow }
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            services.keyWindowSource = { [weak window] in window?.window }
            let dock = try #require(HomeSplitKeysTests.panes(home).first)
            let content = try #require(window.workspaceContent)
            // The walk's earlier flows: four terminal columns right of the dock, each most of the window wide.
            var last = dock.handle
            for count in 2...5 {
                _ = try await connection.newColumn(rightOf: last, width: 0.7)
                try await PasswordManagerRouteTests.until({ HomeSplitKeysTests.panes(home).count == count }, report: { Self.describe(window, home) })
                last = try #require(home.screens.flatMap(\.columns).last?.layout.paneIDs.last)
            }
            try await PasswordManagerRouteTests.until({ content.panes.count == 5 && content.panes.values.allSatisfy { $0.view.window != nil } },
                                                      report: { Self.describe(window, home) })
            let firstColumn = try #require(home.screens.flatMap(\.columns).first { $0.dock == nil }?.layout.paneIDs.first)
            let target = try #require(content.panes.values.first { $0.pane.handle == firstColumn })
            let lastPane = try #require(content.panes.values.first { $0.pane.handle == last })
            let page: InternalPageID = via == "settings" ? .settings : .macScreen
            if from == "again" {
                // A Settings tab already in the first column (the walk's cmd+, flow): showing it again reveals it.
                target.focusContent()
                #expect(services.pages.show(.settings, in: window, focus: true) != nil)
                try await PasswordManagerRouteTests.until({ target.pane.tabs.contains { $0.page == page.rawValue } && Self.onScreen(target, in: window) },
                                                          report: { Self.describe(window, home) })
                let other = try #require(target.pane.tabs.first { $0.page != page.rawValue })
                target.select(StripTabID(other.id))
            }
            // The focus where the walk leaves it, and the camera on the last column (a column revealed beside a chat that
            // kept its focus moves it so, cx-27j7).
            (from == "dock" ? try #require(content.panes.values.first { $0.pane === dock }) : target).focusContent()
            try await PasswordManagerRouteTests.until({ window.focusedPane?.pane === (from == "dock" ? dock : target.pane) },
                                                      report: { Self.describe(window, home) })
            content.layoutModel.revealColumn(containing: lastPane.layoutPaneID)
            try await PasswordManagerRouteTests.until({ Self.onScreen(lastPane, in: window) && !Self.onScreen(target, in: window) },
                                                      report: { "the strip did not scroll the first column away: \(Self.describe(window, home))" })
            if via == "settings" {
                #expect(services.pages.show(.settings, in: window, focus: true) != nil)
            } else {
                let refusal = services.registry.capturingRefusal {
                    #expect(services.registry.perform("macScreen.open", invocation: ActionInvocation(origin: .user)))
                }
                #expect(refusal == nil, "\(refusal ?? "")")
            }
            @MainActor func shown() -> PaneController? {
                content.panes.values.first { pane in
                    guard pane.pane !== dock, let selected = pane.stripModel.selectedID?.rawValue,
                          services.pages.page(ofTab: selected) == page || pane.pane.tabs.first(where: { $0.id == selected })?.page == page.rawValue
                    else { return false }
                    return Self.onScreen(pane, in: window)
                }
            }
            try await PasswordManagerRouteTests.until({ shown() != nil && window.state.page == nil }, report: {
                "\(argument): the \(page.rawValue) page is selected but not drawn inside the window: \(Self.describe(window, home))"
            })
        }
    }
}
