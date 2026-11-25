import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextPalette
@testable import CmuxNextSettings
import CmuxNextSettingsWindow
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Sidebar customization (CMUX-383, Leo: "look at BB and Herder", "as well as adding a proper customizing path"):
/// the ways in and the refusal, drawn from the real views. `diagnostics`: a layout with an unknown token beside the
/// last good one, the rows unchanged, and the toast that names the key and path. `sidebar-menu`: the sidebar's
/// right-click menu with Customize Sidebar… highlighted. `palette`: the command palette filtered to it.
/// Settings > Sidebar's row layout editor joins once cmux#52536 lands.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AASidebarEntryPointGalleryTests {
    enum Variant: String, CaseIterable { case diagnostics, sidebarMenu = "sidebar-menu", palette }

    static let goodJSON = #"{"sidebar":{"workspaceRow":{"lines":[["name"],["directory"]],"linesByAgent":{"codex":[["name","working"],["branch"]],"claude":[["name","branch"],["agentStatus"]]}}}}"#
    /// The same file after a hand edit that wrote `prNumber` (the token is `pullRequest`).
    static let badJSON = #"{"sidebar":{"workspaceRow":{"lines":[["name"],["directory"]],"linesByAgent":{"codex":[["name","working"],["branch","prNumber"]],"claude":[["name","branch"],["agentStatus"]]}}}}"#
    static let badPath = "sidebar.workspaceRow.linesByAgent.codex[1][1]"
    static let paletteQuery = "Customize sidebar"

    static func snapshot(_ json: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), validDensities: [], validMetrics: [])
    }

    /// The toast's notice for the bad file, as `SettingsDiagnosticToasts` builds it.
    static func notice() throws -> SettingsDiagnosticNotices.Notice {
        let snapshot = try snapshot(badJSON)
        var notices = SettingsDiagnosticNotices()
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(badJSON.utf8))
        return try #require(notices.update(snapshot.diagnostics, file: file).announce.first)
    }

    static func toastMessage() throws -> String {
        SettingsDiagnosticStrings.message(try notice(), valueLimit: SettingsDiagnosticToasts.valueLimit)
    }

    // MARK: Sidebar menu

    /// The sidebar background menu as the app builds it, every row bound, Customize Sidebar… through the app's binding.
    static func backgroundMenu() -> NSMenu {
        let registry = ActionRegistry.standard()
        for id in AASidebarDrawnMenuGalleryTests.actions(registry.contextMenuEntries(for: .sidebarBackground)) where id != "sidebar.customize" {
            registry.bind(id, invoke: { _ in })
        }
        SettingsCustomizationActions().bind(into: registry, effect: { _, _ in .done }, refuse: { _ in })
        return registry.makeContextMenu(for: .sidebarBackground)
    }

    /// The menu's row that opens the submenu holding Customize Sidebar… (nil when it is a top row), and that row.
    static func customizePath(_ menu: NSMenu) throws -> (parent: Int?, rows: [GlassMenuRow], child: Int) {
        let found = try #require(ActionRegistry.locate("sidebar.customize", in: menu))
        let top = GlassMenuRow.rows(of: menu)
        if found.menu === menu {
            let child = try #require(top.firstIndex { $0.item.flatMap(ActionRegistry.menuRun(of:))?.id == "sidebar.customize" })
            return (nil, top, child)
        }
        found.menu.update()
        let parent = try #require(top.firstIndex { $0.item?.submenu === found.menu })
        let rows = GlassMenuRow.rows(of: found.menu)
        let child = try #require(rows.firstIndex { $0.item.flatMap(ActionRegistry.menuRun(of:))?.id == "sidebar.customize" })
        return (parent, rows, child)
    }

    // MARK: Palette

    static func palette() async -> PaletteController {
        let registry = ActionRegistry.standard()
        SettingsCustomizationActions().bind(into: registry, effect: { _, _ in .done }, refuse: { _ in })
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        palette.show(.commands)
        palette.model.query = paletteQuery
        await palette.model.settle()
        return palette
    }

    static func closePalette(_ palette: PaletteController) {
        let panels = NSApp.windows.filter { palette.owns($0) }
        palette.hide()
        panels.forEach { $0.close() }
    }

    // MARK: Model

    /// What each variant draws, in words: the three differ, and each is the thing it claims.
    @Test func eachVariantDrawsDistinctContent() async throws {
        _ = NSApplication.shared
        // Diagnostics: the bad file keeps the last good rows and names the key and path.
        let good = try Self.snapshot(Self.goodJSON), bad = try Self.snapshot(Self.badJSON)
        #expect(good.diagnostics.isEmpty)
        #expect(bad.diagnostics.contains { $0.path == Self.badPath })
        let workspaces = Self.workspaces()
        for workspace in workspaces {
            #expect(WorkspaceRowContent(workspace, preferences: bad.sidebarSections.workspaceRow)
                == WorkspaceRowContent(workspace, preferences: good.sidebarSections.workspaceRow), "\(workspace.title) kept its view")
        }
        let message = try Self.toastMessage()
        #expect(message.contains(Self.badPath))
        #expect(message.contains("unknownToken"))
        // Sidebar menu: Customize Sidebar… is a row of the sidebar's right-click menu.
        let path = try Self.customizePath(Self.backgroundMenu())
        let menuItem = try #require(path.rows[path.child].item)
        #expect(menuItem.isEnabled)
        // Palette: the filtered palette leads with it.
        let palette = await Self.palette()
        defer { Self.closePalette(palette) }
        let first = try #require(palette.model.rows.first)
        #expect(first.id == "action:sidebar.customize", "palette leads with \(palette.model.rows.prefix(3).map(\.id))")
        let drawn = [message, "menu: " + menuItem.title, "palette: " + first.item.title]
        #expect(Set(drawn).count == Variant.allCases.count)
    }

    // MARK: Drawing

    static func workspaces() -> [SidebarWorkspace] {
        var codex = WorkspaceRowLayoutRenderingTests.workspace()
        codex.title = "Sidebar customization"
        codex.agentWorking = true
        codex.status = "Checking the layout"
        var claude = SidebarWorkspace(id: WorkspaceID("claude"), title: "Project notes", directory: "~/notes", branch: "draft",
                                      rowKind: .agent, kind: .harness, activity: .idle)
        claude.kindBrand = "claude"
        claude.status = "Ready for review"
        let terminal = SidebarWorkspace(id: WorkspaceID("terminal"), title: "Build logs", directory: "~/project", branch: "feature",
                                        rowKind: .terminal, kind: .terminal, activity: .idle)
        return [codex, claude, terminal]
    }

    @MainActor final class Stage {
        let window: NSWindow
        let root: NSView
        let scope: ThemeScope

        init(width: CGFloat, height: CGFloat, dark: Bool) throws {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            root.wantsLayer = true
            root.appearance = window.appearance
            window.contentView = root
            let theme = dark ? "Soft Blue" : "Soft Blue Light"
            let input = try AANestedGroupsGalleryTests.input(theme)
            _ = ThemeScope.app.store.apply(input)
            scope = ThemeScope(level: .room)
            scope.setOverride(ThemeSpec(theme), input: input, animated: false)
            scope.root(root)
            root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
            window.orderFrontRegardless()
        }

        /// The real sidebar with `json`'s row layout, at `frame`.
        @discardableResult
        func sidebar(_ json: String, frame: NSRect) throws -> SidebarView {
            let preferences = try AASidebarEntryPointGalleryTests.snapshot(json).sidebarSections.workspaceRow
            let design = DesignSettings()
            var sections = design.sidebarSections
            sections.workspaceRow = preferences
            design.sidebarSections = sections
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine),
                                                               nodes: AASidebarEntryPointGalleryTests.workspaces().map { .workspace($0) })])
            model.workspaceRow = preferences
            let sidebar = SidebarView(model: model, design: design)
            sidebar.frame = frame
            root.addSubview(sidebar)
            sidebar.renderNow()
            sidebar.list.reload(animated: false)
            return sidebar
        }

        func label(_ text: String, at point: NSPoint) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.sizeToFit()
            label.setFrameOrigin(point)
            root.addSubview(label)
        }

        func capture() throws -> CGImage {
            root.layoutSubtreeIfNeeded()
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return try #require(rep.cgImage)
        }

        func close() { window.close() }
    }

    /// The last good layout and the bad edit side by side, and the toast the app shows for it under them.
    static func renderDiagnostics(dark: Bool) throws -> CGImage {
        let side: CGFloat = 300, gap: CGFloat = 16, labelHeight: CGFloat = 22, toastArea: CGFloat = 120
        let width = side * 2 + gap * 3, height = labelHeight + side + toastArea
        let stage = try Stage(width: width, height: height, dark: dark)
        defer { stage.close() }
        stage.label("Last good layout", at: NSPoint(x: gap, y: height - labelHeight + 4))
        stage.label("After saving \"prNumber\" (unknown token)", at: NSPoint(x: gap * 2 + side, y: height - labelHeight + 4))
        try stage.sidebar(goodJSON, frame: NSRect(x: gap, y: toastArea, width: side, height: side))
        try stage.sidebar(badJSON, frame: NSRect(x: gap * 2 + side, y: toastArea, width: side, height: side))
        let refusal = try Self.notice()
        let destination = SettingsDiagnosticToasts.destination(refusal.path, file: refusal.file)
        let toast = CmuxToast(id: SettingsDiagnosticToasts.toastID, message: try toastMessage(),
                              action: CmuxToast.Action(title: destination == .file ? SettingsDiagnosticStrings.openFile
                                  : SettingsDiagnosticStrings.showInSettings),
                              duration: CmuxToast.untilClosed)
        let view = stage.scope.perform { CmuxToastView(toast: toast, reduceTransparency: .alwaysOpaque) }
        stage.root.addSubview(view)
        view.layoutSubtreeIfNeeded()
        var size = view.fittingSize
        size.width = min(size.width, width - gap * 2)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(x: (width - size.width) / 2, y: max(gap, (toastArea - size.height) / 2), width: size.width, height: size.height)
        return try stage.capture()
    }

    /// The sidebar right-clicked below its rows: the background menu, drawn as the drawn-menus look draws it, with the
    /// row that holds Customize Sidebar… open beside it and Customize Sidebar… highlighted.
    static func renderSidebarMenu(dark: Bool) throws -> CGImage {
        let menu = backgroundMenu()
        let path = try customizePath(menu)
        let list = GlassMenuListView(), top = GlassMenuRow.rows(of: menu)
        list.load(top)
        let size = list.fittingMenuSize()
        let child = GlassMenuListView()
        if path.parent != nil { child.load(path.rows) }
        let childSize = path.parent != nil ? child.fittingMenuSize() : .zero
        let side: CGFloat = 300, click: CGFloat = 150, gap: CGFloat = 4, margin: CGFloat = 16
        let width = max(side, click + size.width + gap + childSize.width + margin)
        let height = max(side, size.height + 2 * margin + 120)
        let stage = try Stage(width: width, height: height, dark: dark)
        defer { stage.close() }
        try stage.sidebar(goodJSON, frame: NSRect(x: 0, y: 0, width: side, height: height))
        let panel = Glass.makeMenuPanel(content: list)
        panel.frame = NSRect(x: click, y: height - 120 - size.height, width: size.width, height: size.height)
        stage.root.addSubview(panel)
        panel.layoutSubtreeIfNeeded()
        list.frame = panel.contentView.bounds
        list.layoutSubtreeIfNeeded()
        if let parent = path.parent {
            list.highlight(parent)
            let hovered = try #require(list.view(at: parent))
            let anchor = stage.root.convert(hovered.convert(hovered.bounds, to: nil), from: nil)
            let sidePanel = Glass.makeMenuPanel(content: child)
            sidePanel.frame = PopupPlacement.sideBySideFrame(anchor: anchor, size: childSize, screen: stage.root.bounds,
                                                             gap: gap, margin: 0).frame
            stage.root.addSubview(sidePanel)
            sidePanel.layoutSubtreeIfNeeded()
            child.frame = sidePanel.contentView.bounds
            child.layoutSubtreeIfNeeded()
            child.highlight(path.child)
        } else {
            list.highlight(path.child)
        }
        return try stage.capture()
    }

    /// The command palette filtered to "Customize sidebar", over the window it opens on.
    static func renderPalette(dark: Bool) async throws -> CGImage {
        let palette = await palette()
        defer { closePalette(palette) }
        let view = PaletteContentView(model: palette.model)
        let margin: CGFloat = 24
        let width = view.frame.width + margin * 2, height = view.frame.height + margin * 2
        let stage = try Stage(width: width, height: height, dark: dark)
        defer { stage.close() }
        view.setFrameOrigin(NSPoint(x: margin, y: margin))
        stage.root.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return try stage.capture()
    }

    static func render(_ variant: Variant, dark: Bool) async throws -> CGImage {
        switch variant {
        case .diagnostics: try renderDiagnostics(dark: dark)
        case .sidebarMenu: try renderSidebarMenu(dark: dark)
        case .palette: try await renderPalette(dark: dark)
        }
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot, out = root.appending(path: "sidebar-entry-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Rows: dark, then light. Columns: one per variant, as wide as its widest image.
        var grid: [[CGImage]] = []
        for dark in [true, false] {
            var row: [CGImage] = []
            for variant in Variant.allCases {
                let image = try await Self.render(variant, dark: dark)
                row.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(variant.rawValue).png"))
            }
            grid.append(row)
        }
        let gap = 16
        let widths = Variant.allCases.indices.map { column in grid.map { $0[column].width }.max() ?? 0 }
        let heights = grid.map { $0.map(\.height).max() ?? 0 }
        let total = (width: widths.reduce(0, +) + gap * (widths.count - 1), height: heights.reduce(0, +) + gap * (heights.count - 1))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: total.width, height: total.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: total.width, height: total.height))
        var top = total.height
        for (r, row) in grid.enumerated() {
            top -= heights[r]
            var x = 0
            for (c, image) in row.enumerated() {
                context.draw(image, in: CGRect(x: x, y: top + heights[r] - image.height, width: image.width, height: image.height))
                x += widths[c] + gap
            }
            top -= gap
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(context.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-entry-gallery.tar", "sidebar-entry-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
