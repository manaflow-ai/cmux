import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-P with "workspace" typed (Lawrence 2026-11-15: "search workspaces looks bad. the icon
/// looks bad too."): the keyword hint ("Search Workspaces ⇥") right of the field, the Workspaces
/// scope row with its `#` key, and the workspace rows with their "Workspace" kind label ended at
/// three different right edges, the scope row repeated what its `#` key and the field's hint already
/// say ("Type #, or workspaces and Tab"), and a workspace row drew the system's stacked rectangles
/// where every other surface draws cmux's own workspace glyph.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteWorkspaceSearchPolishTests {
    @MainActor private final class Store: PaletteWorkspaceSource {
        let workspaces = (0..<12).map { PaletteWorkspace(id: "w\($0)", title: "workspace-\(900 + $0)") }
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func open(_ query: String, store: Store) async -> PaletteController {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: store), frecencyPersistence: nil)
        palette.bindRegistryActions()
        _ = registry.perform("commandPalette", invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        return palette
    }

    /// The rightmost column of `view`'s own drawing with any ink (a keycap's faint fill counts), in
    /// `root`'s coordinates; nil when it draws nothing.
    private static func inkMaxX(of view: NSView, in root: NSView) throws -> CGFloat? {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                return view.convert(NSPoint(x: CGFloat(x + 1) / scale, y: 0), to: root).x
            }
        }
        return nil
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The hint's key, the scope row's `#` key and each workspace row's kind label end on one right
    /// edge, in light and dark and at every density.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func hintKeysAndKindLabelsShareOneRightEdge(appearance: NSAppearance.Name) async throws {
        let store = Store()
        let palette = await Self.open("workspace", store: store)
        defer { palette.closeForTest() }
        #expect(palette.model.keywordHint?.scope == PaletteScopeID.workspaces, "the field shows the Search Workspaces hint")
        for preset in DensityPreset.allCases {
            try DensityTokens.$scoped.withValue(preset.tokens) {
                let view = PaletteContentView(model: palette.model)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: PaletteLayout.windowSize), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                defer { window.closeAfterTest() }
                // As on a Mac with a mouse ("Show scroll bars: Automatic"), where AppKit gave the
                // list a legacy scroller with a gray track that took 15 pt from every row.
                for scrollView in Self.views(NSScrollView.self, in: view) { scrollView.scrollerStyle = .legacy }
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let label = "\(preset.tokens.name), \(appearance.rawValue)"
                let hint = try #require(try Self.inkMaxX(of: view.searchBar, in: view), "\(label): the hint draws")
                let cells = Self.views(PaletteRowCell.self, in: view).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
                #expect(cells.count >= 4, "\(label): \(cells.count) rows")
                let edges = try cells.compactMap { try Self.inkMaxX(of: $0, in: view) }
                #expect(edges.count == cells.count, "\(label): every row draws a key or a kind label at its right")
                for edge in edges {
                    #expect(abs(edge - hint) <= 1, "\(label): a row ends at \(edge), the field's hint at \(hint)")
                }
                // The panel's right inset mirrors its left one: where the field's magnifier glyph starts.
                let panelRight = view.glass.frame.maxX
                let left = view.searchBar.subviews.first { $0 is NSImageView && !$0.isHidden }.map { view.convert($0.frame, from: view.searchBar).minX }
                let leftInset = try #require(left) + (PaletteLayout.iconBox - Metrics.iconSize) / 2 - view.glass.frame.minX
                #expect(abs((panelRight - hint) - leftInset) <= 1,
                        "\(label): right inset \(panelRight - hint), left inset \(leftInset)")
            }
        }
    }

    /// The Workspaces scope row shows its `#` key and no sentence: the key and the field's hint say
    /// how to enter it.
    @Test func theScopeRowLetsItsKeyTeachThePrefix() async throws {
        let palette = await Self.open("workspace", store: Store())
        defer { palette.closeForTest() }
        let row = try #require(palette.model.rows.first { $0.item.id == "scope:workspaces" })
        #expect(row.item.keycaps == ["#"])
        #expect(row.item.subtitle == nil, "\(row.item.subtitle ?? "")")
    }

    /// A workspace row draws cmux's workspace glyph (window with sidebar), as the sidebar and menus
    /// do, not the system's stacked rectangles.
    @Test func aWorkspaceRowDrawsTheWorkspaceGlyph() async throws {
        let palette = await Self.open("workspace", store: Store())
        defer { palette.closeForTest() }
        let row = try #require(palette.model.rows.first { $0.item.id.hasPrefix("workspace:") })
        let symbol = try #require(row.item.symbol)
        let drawn = try #require(PaletteText.symbol(symbol, size: Metrics.iconSize))
        // The pack's icon in place of the system symbol, as the sidebar draws a workspace.
        let pack = try #require(NSImage.packOverride(forSymbol: symbol, pointSize: Metrics.iconSize), "\(symbol) has a pack icon")
        #expect(drawn.tiffRepresentation == pack.tiffRepresentation, "\(symbol) draws the pack's workspace glyph")
    }
}
