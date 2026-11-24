import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-24, "this idk", on the workspace hover card's split miniature (tiles that were an icon in a box):
/// the card over `AAWorkspaceHoverCardVariantsGalleryTests.render`'s backdrop, dark and light, for four looks of
/// Leo's three-pane layout. `CMUX_TEST_REQUIRE_GUI=1`; writes `hover-card-panes/` and `hover-card-panes.tar`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkspaceHoverCardPanesGalleryTests {
    enum Look: String, CaseIterable {
        case bare = "A  before: a kind glyph in each tile"
        case titles = "B  title and state in each tile"
        case pictures = "C  the tab's picture fills each tile"
        case mixed = "D  chosen: a picture when there is one, else title and state"
    }

    static let tabs: [SidebarTab] = [
        SidebarTab(id: TabID("pr"), title: "PR 36460 · GitHub", kind: .browser, host: "github.com"),
        SidebarTab(id: TabID("shell"), title: "cmux-tui watch", kind: .terminal, folder: "~/fun/cmux", state: .busy),
        SidebarTab(id: TabID("chat"), title: "Mango", kind: .agentChat, brand: "claude", state: .waiting),
    ]

    static let shape = SidebarPaneShape.split(
        axis: .horizontal, ratio: 0.5,
        .pane(.init(kind: .browser, focused: true, tab: "pr")),
        .split(axis: .vertical, ratio: 0.5, .pane(.init(kind: .terminal, tab: "shell")), .pane(.init(kind: .harness, tab: "chat"))))

    static func card(_ look: Look) -> WorkspaceHoverCardView {
        let card = WorkspaceHoverCardView()
        let content = WorkspaceHoverCardFixture.content
        card.configure(content, now: WorkspaceHoverCardFixture.now)
        card.configureTabs(title: content.title, tabs: tabs, now: WorkspaceHoverCardFixture.now)
        card.configurePaneShape(shape, tabs: look == .bare ? [] : tabs)
        if look == .pictures || look == .mixed {
            card.paneShape.setImage(AATabHoverCardSweepGalleryTests.page(seed: 1), for: "pr")
        }
        if look == .pictures {
            card.paneShape.setImage(AATabHoverCardSweepGalleryTests.page(seed: 2), for: "shell")
            card.paneShape.setImage(AATabHoverCardSweepGalleryTests.page(seed: 3), for: "chat")
        }
        return card
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "hover-card-panes")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var shots: [Bool: [CGImage]] = [true: [], false: []]
        for dark in [true, false] {
            for look in Look.allCases {
                let image = try AAWorkspaceHoverCardVariantsGalleryTests.labeled(
                    try AAWorkspaceHoverCardVariantsGalleryTests.render(dark: dark) { Self.card(look) }, look.rawValue, dark: dark)
                shots[dark]?.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(String(look.rawValue.prefix(1)).lowercased())-\(dark ? "dark" : "light").png"))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try AAWorkspaceHoverCardVariantsGalleryTests.sheet(shots[true] ?? [], shots[false] ?? [], columns: 4),
                                                   to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "hover-card-panes.tar", "hover-card-panes"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
