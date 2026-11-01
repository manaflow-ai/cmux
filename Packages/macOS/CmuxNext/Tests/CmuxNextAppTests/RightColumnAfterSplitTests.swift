import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Review of #29787 at 29861047: what opens on the right right after a split read the panes' widths
/// from their views, not from the layout. While the split's spring runs, the source pane still shows
/// its width from before the split (its content is held at that size until the spring lands) and the
/// new pane starts at a sliver. In a window narrower than twice the chat floor, the source read about
/// 880 pt instead of about 440, so a link (or an agent's side chat or subagent) opened at once went
/// to a new split below the pane on the right instead of a tab in it, the place it takes once both
/// panes are measured. A script or agent that splits and then opens at once hit it every time.
///
/// The test is the layout's clock (`DisplayLinkDriver.isManual`), so the split's spring stays at its
/// first frame for every open below: the race is the same on every host.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct RightColumnAfterSplitTests {
    static let link = URL(string: "https://github.com/manaflow-ai/cmux/pull/2")!

    /// A split, then at once a link from the source and the agent path's measure of the same column.
    /// The pane on the right holds only the split's terminal, so neither the same-kind rule nor a
    /// lower pane decides: only the widths do.
    @Test func anOpenRightAfterASplitReadsThePanesFinalWidths() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let window = try #require(services.windows.active?.window)
            let content = try #require(services.windows.active?.workspaceContent)
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let pane = try #require(services.paneController(for: model))
            let sourceTab = try #require(model.tabs.first?.id)
            services.linkOpener.placement = { .splitRight }
            let root = content.layoutView
            // Pins the pane springs on without touching the shared settings.
            root.context.reduceMotionOverride = false

            // A window narrower than twice the chat floor: one pane is wide enough to split, each half is not.
            window.setFrame(NSRect(x: 100, y: 100, width: 940, height: 700), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let floor = RightColumnPlacement.minimumChatWidth
            try await PinnedPageTests.until({ LinkOpener.width(of: pane).map { $0 >= floor && $0 < 2 * floor } == true },
                                            report: { "fixture: the lone pane is \(String(describing: LinkOpener.width(of: pane))) pt, wanted \(floor) to \(2 * floor)" })
            // From here the test is the clock: the split's spring never steps on its own. Re-attaching
            // stops a clock already running (a fade), which would otherwise step the spring too.
            root.driver.isManual = true
            root.driver.detach()
            root.driver.attach(to: root)
            defer { root.driver.isManual = false }

            let right = try await Self.splitRight(services, content)
            let springing = root.screenViews.values.contains { $0.hasMotion }
            try #require(springing, "fixture: the split's spring has landed already")
            try #require(LinkOpener.rightPanes(beside: pane.layoutPaneID, in: content) == [right.layoutPaneID],
                         "fixture: the right column is not the split's pane")
            try #require(!LinkOpener.holds(right, .browser), "fixture: the pane on the right holds a browser")

            // The width the source rests at once the split lands, not the one its view still shows.
            #expect(LinkOpener.width(of: pane).map { $0 < floor } == true,
                    "the source read \(String(describing: LinkOpener.width(of: pane))) pt after the split, its width before it")

            // Agent opens (AgentSidePanes, AgentSubagentPanes, AgentBesidePlacement) measure through `rightColumn`.
            let measured = services.agentTabs.rightColumn(sourceTab)
            #expect(RightColumnPlacement.decide(measured) == .tab(right.layoutPaneID.rawValue),
                    "an agent's open right after the split: \(measured)")

            // The link, at once: a tab in the pane on the right, never a split below it.
            #expect(services.linkOpener.target(from: pane, kind: .browser) == .pane(right.layoutPaneID),
                    "the link's place right after the split: \(Self.describe(content))")
            let before = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            let panes = Set(content.panes.keys)
            #expect(services.linkOpener.openWeb(Self.link, from: pane, background: false))
            @MainActor func opened() -> String? {
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .first { !before.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }?.id
            }
            try await PinnedPageTests.until({ opened() != nil && !services.linkOpener.turns.isBusy(beside: pane.layoutPaneID) },
                                            report: { "the link did not land: " + Self.describe(content) })
            let tab = try #require(opened())
            #expect(right.pane.tabs.contains { $0.id == tab }, "the link's tab is not in the pane on the right: \(Self.describe(content))")
            #expect(Set(content.panes.keys) == panes, "the link split the window again: \(Self.describe(content))")
        }
    }

    /// Splits the focused pane right and gives the new pane's controller once the daemon confirmed it
    /// (as ``ClickedLinkFocusTests`` does): a tab aimed at the provisional pane is refused until then.
    private static func splitRight(_ services: AppServices, _ content: WorkspaceContentController) async throws -> PaneController {
        let panes = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
        func confirmed() -> PaneController? {
            content.panes.first { !panes.contains($0.key) && $0.value.pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }?.value
        }
        try await PinnedPageTests.until({ confirmed() != nil }, report: { "the split did not confirm" })
        return try #require(confirmed())
    }

    /// Each pane, its measured width and its tabs.
    private static func describe(_ content: WorkspaceContentController) -> String {
        content.panes.values.map { pane in
            "\(pane.layoutPaneID) (\(LinkOpener.width(of: pane).map { "\(Int($0)) pt" } ?? "unmeasured")): \(pane.pane.tabs.map(\.id))"
        }.sorted().joined(separator: "; ")
    }
}
