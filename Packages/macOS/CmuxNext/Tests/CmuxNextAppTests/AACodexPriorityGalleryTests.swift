import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The Codex app's priority view in the sidebar's Priority view, light and dark: today's panel (the keys at their
/// defaults), then the Codex keys on (`sidebar.priorityView.filters`, `.showIdle` off, `.statusWords`) under each
/// filter. Several chats in each tier: two waiting on the person, two finished unseen, a failed one, Red CI, two
/// running (one on another machine) and an idle one. Artifact `codex-priority-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized, .closesItsWindows) struct AACodexPriorityGalleryTests {
    static let now = Date()
    static let codex = SidebarItemInfo.agentBrand(forHarness: "codex"), claude = SidebarItemInfo.agentBrand(forHarness: "claude")

    static let entries: [SidebarPriorityEntry] = [
        SidebarPriorityEntry(id: "ask-1", title: "Run the migration?", project: "api", preview: "Wants to run: bun run db:migrate",
                             state: .needsYou, brand: codex),
        SidebarPriorityEntry(id: "ask-2", title: "Pick an auth provider", project: "web", preview: "Asks: keep sessions or move to tokens?",
                             state: .needsYou, brand: claude),
        SidebarPriorityEntry(id: "done-1", title: "Fix the flaky login test", project: "web",
                             preview: "The test now waits for the redirect before it checks the cookie.", state: .done, unread: true, brand: codex),
        SidebarPriorityEntry(id: "done-2", title: "Release notes draft", project: "docs", preview: "Wrote 6 highlights from this week's merges.",
                             state: .done, unread: true, brand: claude),
        SidebarPriorityEntry(id: "fail-1", title: "Bump dependencies", project: "api", preview: "Build failed: 3 type errors in the client",
                             state: .failed, unread: true, brand: codex),
        SidebarPriorityEntry(id: "ci-1", title: "Sidebar refactor", project: "app", preview: "2 checks failing on the pull request",
                             state: .ciFailing, brand: codex),
        SidebarPriorityEntry(id: "run-1", title: "Port ranking to Rust", project: "core", preview: "Editing ranking.rs",
                             state: .working(since: now.addingTimeInterval(-5 * 60)), brand: codex),
        SidebarPriorityEntry(id: "run-2", title: "Index the docs", project: "docs", machine: "gpu-box", preview: "Reading 40 files",
                             state: .working(since: now.addingTimeInterval(-12 * 60)), brand: claude),
        SidebarPriorityEntry(id: "idle-1", title: "Archive old branches", project: "app", preview: "Removed 14 merged branches.",
                             state: .idle, brand: codex),
    ]

    /// Today's panel, or the Codex keys' under `filter`.
    static func panel(codex filter: SidebarPriorityFilter?) -> SidebarPriorityPanel {
        guard let filter else { return SidebarPriorityPanel(entries: entries) }
        let listed = entries.filter { $0.state != .idle }
        return SidebarPriorityPanel(entries: listed.filter(filter.includes), filters: SidebarPriorityFilterBar(selected: filter, all: listed),
                                    statusWords: true)
    }

    static func render(_ panel: SidebarPriorityPanel, dark: Bool) throws -> CGImage {
        let (_, sidebar, window) = SidebarRowCloseSpotTests.sidebar()
        defer { window.close() }
        let size = NSSize(width: 300, height: 1400)
        window.setContentSize(size)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        sidebar.showPriority(panel)
        sidebar.renderNow()
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        // The sidebar's top: the titlebar row, the Priority view and the first list rows.
        let shown = NSRect(x: 0, y: max(0, root.bounds.height - 720), width: root.bounds.width, height: min(720, root.bounds.height))
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: shown))
        root.cacheDisplay(in: shown, to: rep)
        return try #require(rep.cgImage)
    }

    @Test func theFilterBarShowsOnlyWithTheKeyAndCountsEveryRow() {
        #expect(Self.panel(codex: nil).filters == nil)
        let bar = Self.panel(codex: .unread).filters
        #expect(bar?.count(.all) == 8 && bar?.count(.waiting) == 2 && bar?.count(.unread) == 3 && bar?.count(.running) == 2)
        #expect(Self.panel(codex: .unread).entries.map(\.id) == ["done-1", "done-2", "fail-1"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderTheCodexPriorityView() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "codex-priority-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let variants: [(String, SidebarPriorityFilter?)] = [("default", nil), ("codex-all", .all), ("codex-waiting", .waiting),
                                                            ("codex-unread", .unread), ("codex-running", .running)]
        for (name, filter) in variants {
            for dark in [true, false] {
                let image = try Self.render(Self.panel(codex: filter), dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "codex-priority-gallery.tar", "codex-priority-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
