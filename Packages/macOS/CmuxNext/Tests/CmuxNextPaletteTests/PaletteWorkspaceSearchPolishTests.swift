import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Cmd-Shift-P (then also Cmd-P) with "workspace" typed (Lawrence 2026-11-15: "search workspaces looks bad. the icon
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

    /// `action`: Cmd-Shift-P (`commandPalette`, the keyword hint and the scope row) or Cmd-P (`goToWorkspace`, the
    /// workspace rows; Cmd-Shift-P lists no workspace since msg 34162).
    private static func open(_ query: String, store: Store, action: ActionID = "commandPalette") async -> PaletteController {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: store), frecencyPersistence: nil)
        palette.bindRegistryActions()
        _ = registry.perform(action, invocation: ActionInvocation(arguments: [:], origin: .user))
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
        let goTo = await Self.open("workspace", store: store, action: "goToWorkspace")
        defer {
            palette.closeForTest()
            goTo.closeForTest()
        }
        #expect(palette.model.keywordHint?.scope == PaletteScopeID.workspaces, "the field shows the Search Workspaces hint")
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.closeAfterTest() } }
        func render(_ model: PaletteModel) -> PaletteContentView {
            let view = PaletteContentView(model: model)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: PaletteLayout.windowSize), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            windows.append(window)
            // As on a Mac with a mouse ("Show scroll bars: Automatic"), where AppKit gave the
            // list a legacy scroller with a gray track that took 15 pt from every row.
            for scrollView in Self.views(NSScrollView.self, in: view) { scrollView.scrollerStyle = .legacy }
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            return view
        }
        func cells(_ view: NSView) -> [PaletteRowCell] {
            Self.views(PaletteRowCell.self, in: view).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
        }
        for preset in DensityPreset.allCases {
            try DensityTokens.$scoped.withValue(preset.tokens) {
                let view = render(palette.model), goToView = render(goTo.model)
                let label = "\(preset.tokens.name), \(appearance.rawValue)"
                let hint = try #require(try Self.inkMaxX(of: view.searchBar, in: view), "\(label): the hint draws")
                // Cmd-P's workspace rows each end in their kind label.
                let workspaceRows = cells(goToView)
                #expect(workspaceRows.count >= 4, "\(label): \(workspaceRows.count) workspace rows")
                let workspaceEdges = try workspaceRows.compactMap { try Self.inkMaxX(of: $0, in: goToView) }
                #expect(workspaceEdges.count == workspaceRows.count, "\(label): every workspace row draws its kind label")
                // Cmd-Shift-P's rows that draw at their right (the scope row's # key, a shortcut, a kind label).
                let commandEdges = try cells(view).compactMap { try Self.inkMaxX(of: $0, in: view) }.filter { $0 > view.glass.frame.midX }
                #expect(!commandEdges.isEmpty, "\(label): the scope row draws its key")
                for edge in workspaceEdges + commandEdges {
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
        let palette = await Self.open("workspace", store: Store(), action: "goToWorkspace")
        defer { palette.closeForTest() }
        let row = try #require(palette.model.rows.first { $0.item.id.hasPrefix("workspace:") })
        let symbol = try #require(row.item.symbol)
        let drawn = try #require(PaletteText.symbol(symbol, size: Metrics.iconSize))
        // The pack's icon in place of the system symbol, as the sidebar draws a workspace.
        let pack = try #require(NSImage.packOverride(forSymbol: symbol, pointSize: Metrics.iconSize), "\(symbol) has a pack icon")
        #expect(drawn.tiffRepresentation == pack.tiffRepresentation, "\(symbol) draws the pack's workspace glyph")
    }
}
