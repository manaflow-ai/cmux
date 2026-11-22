import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Leo 2026-10-18: selected sidebar rows looked awkward on a themed background next to the neutral
/// default. An accent theme drew the active row in its accent and the other drag-selected rows in
/// neutral grey, and a dragged row dropped its selection for a plain card. Every selected row now
/// reads as one selection in the theme's selection color, in the list and on the lifted card.
/// With CMUX_SIDEBAR_SELECTION_GALLERY (a folder) the gallery test renders each theme, at rest and
/// mid-drag, to sidebar-selection.png there.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarSelectionLookTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    nonisolated static let themes = ["Soft Blue", "Soft Blue Light", "Clay Orange", "Clay Orange Light"]

    static func input(_ name: String) throws -> ThemeInput {
        guard name != "Default" else { return ThemeInput.ghosttyDefault }
        let text = try String(contentsOf: repoRoot.appending(path: "Resources/cmux-themes/\(name)"), encoding: .utf8)
        let file = try #require(ThemeFileColors(name: name, themeFile: text))
        var input = ThemeInput(background: file.background, foreground: file.foreground, palette: file.palette.compactMap { $0 },
                               selectionBackground: file.selectionBackground, selectionForeground: file.selectionForeground)
        input.accentColor = file.accent
        return input
    }

    static func sidebar(_ name: String) throws -> (SidebarListView, NSWindow, [WorkspaceID]) {
        _ = NSApplication.shared
        let ids = (1...4).map { WorkspaceID("ws-\($0)") }
        let workspaces = ids.enumerated().map { SidebarWorkspace(id: $0.element, title: "workspace-\($0.offset + 1)") }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 220, height: 170), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 170))
        root.wantsLayer = true
        window.contentView = root
        // The app's theme too, as the app sets it: a lifted row is configured before it joins the window.
        _ = ThemeScope.app.store.apply(try input(name))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: try input(name), animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        model.click(ids[1])
        model.toggleSelection(ids[2])
        list.reload(animated: false)
        return (list, window, ids)
    }

    static func snapshot(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The rows of a multi-selection are the selection's own color, lighter, in every theme.
    @Test(arguments: ["Default"] + themes) func multiSelectedRowsTakeTheSelectionColor(_ name: String) throws {
        let tokens = ThemeTokens.derive(from: try Self.input(name))
        let (selection, secondary) = (tokens.selectionFill, tokens.secondarySelectionFill)
        #expect(abs(secondary.alpha / selection.alpha - 0.7) < 0.02, "\(name): \(secondary.alpha) of \(selection.alpha)")
        #expect(secondary.withAlpha(1) == selection.withAlpha(1), "\(name): one hue")
    }

    /// A dragged selected row keeps its selection fill on the lifted card.
    @Test func aLiftedSelectedRowKeepsItsFill() throws {
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        let (list, window, ids) = try Self.sidebar("Clay Orange Light")
        defer { window.close() }
        let row = try #require(list.displayed.rows.first { $0.key == .workspace(ids[1]) })
        let start = NSPoint(x: 60, y: row.y + row.height / 2)
        list.press = SidebarPress(key: row.key, point: start)
        list.beginDrag(try #require(list.press))
        defer { list.finishDrag() }
        let lift = try #require(list.subviews.first { $0 is DragLiftView })
        let lifted = try #require(Self.rows(in: lift).first)
        #expect(lifted.isSelected)
        // Its display pass, run now: the fill it paints there.
        lifted.updateLayer()
        #expect(lifted.paintsFill)
        #expect(lift.accessibilityChildren()?.isEmpty == true, "the card shows no second selected row to VoiceOver")
    }

    private static func rows(in view: NSView) -> [WorkspaceRowView] {
        ((view as? WorkspaceRowView).map { [$0] } ?? []) + view.subviews.flatMap { rows(in: $0) }
    }

    @Test func galleryOfSelectedRows() async throws {
        guard let out = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SELECTION_GALLERY"] else { return }
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        var shots: [(CGImage, CGImage)] = []
        for name in ["Default"] + Self.themes {
            let (list, window, ids) = try Self.sidebar(name)
            defer { window.close() }
            let rest = try #require(Self.snapshot(window.contentView!))
            let row = try #require(list.displayed.rows.first { $0.key == .workspace(ids[1]) })
            let start = NSPoint(x: 60, y: row.y + row.height / 2)
            list.press = SidebarPress(key: row.key, point: start)
            list.beginDrag(try #require(list.press))
            list.updateDrag(windowPoint: list.convert(NSPoint(x: 64, y: start.y + 30), to: nil))
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
            let dragging = try #require(Self.snapshot(window.contentView!))
            list.finishDrag()
            shots.append((rest, dragging))
        }
        let w = shots[0].0.width, h = shots[0].0.height, gap = 8
        let ctx = try #require(CGContext(data: nil, width: (w + gap) * 2, height: (h + gap) * shots.count, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, pair) in shots.enumerated() {
            let y = ctx.height - (index + 1) * (h + gap)
            ctx.draw(pair.0, in: CGRect(x: 0, y: y, width: w, height: h))
            ctx.draw(pair.1, in: CGRect(x: w + gap, y: y, width: w, height: h))
        }
        let image = try #require(ctx.makeImage())
        let url = URL(fileURLWithPath: out).appending(path: "sidebar-selection.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
