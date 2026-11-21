import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Testing

/// Lawrence 2026-11-20 ("these colors look horrible by default", a sidebar row "workspace-1005" with a bright blue bar
/// down its whole left edge): a picked workspace color drew, in the default `leftRail` style, as the vibrant swatch at
/// full strength (blue #62A7FD on the dark sidebar, 7:1, as loud as the row's title) the whole height of the row.
///
/// The contract, in every bundled theme, light and dark, for every color a person can pick:
/// - at rest the bar is a quiet mark: its contrast with the sidebar is at most ``restMaximum`` (the title reads first),
///   and it never vanishes (at least ``visibleMinimum``);
/// - it is a short mark on the title's line, not a stripe down the row: no taller than the title's line;
/// - a selected row's bar is stronger than a resting row's, so the selection stays clear;
/// - a row with no picked color draws no bar at all.
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceColorRailIsQuietTests {
    nonisolated static let themes = ["Default", "Soft Blue", "Soft Blue Light", "Clay Orange", "Clay Orange Light", "Olive Grey"]
    /// A resting bar's highest contrast with the sidebar: the title (about 9:1 or more) leads.
    static let restMaximum = 2.6
    /// A selected bar's highest contrast with the sidebar.
    static let selectedMaximum = 3.6
    /// Every bar still reads as a color mark.
    static let visibleMinimum = 1.25

    /// One row, `color` picked (or none), laid out and drawn in theme `name` with default sidebar settings.
    static func row(_ name: String, color: GroupColor?, selected: Bool = false) throws -> (WorkspaceRowView, NSWindow, ThemeTokens) {
        _ = NSApplication.shared
        let input = try SidebarSelectionLookTests.input(name)
        let tokens = ThemeTokens.derive(from: input)
        let ws = SidebarWorkspace(id: WorkspaceID("ws-\(color?.rawValue ?? "plain")"), title: "workspace-1005",
                                  icon: color.map(WorkspaceIcon.swatch), color: color)
        let options = SidebarLayoutOptions() // the default style, `leftRail`
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: options.rowContent(ws, machine: nil))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 28), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        root.wantsLayer = true
        window.contentView = root
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(name), input: input, animated: false)
        scope.root(root)
        let view = WorkspaceRowView(key: row.key)
        root.addSubview(view)
        view.frame = root.bounds
        view.configure(ws, row: row)
        view.isSelected = selected
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.updateLayer()
        return (view, window, tokens)
    }

    /// The sidebar the bar draws on: its background over the window's, opaque.
    static func backdrop(_ tokens: ThemeTokens) -> ThemeRGB {
        over(tokens.sidebarBackground, tokens.windowBackground.withAlpha(1))
    }

    static func over(_ top: ThemeRGB, _ bottom: ThemeRGB) -> ThemeRGB {
        let a = top.alpha
        return ThemeRGB(red: top.red * a + bottom.red * (1 - a), green: top.green * a + bottom.green * (1 - a),
                        blue: top.blue * a + bottom.blue * (1 - a))
    }

    /// The bar's color as drawn over the sidebar, and its contrast with it.
    static func barContrast(_ view: WorkspaceRowView, _ tokens: ThemeTokens) throws -> Double {
        let cg = try #require(view.colorRail.layer?.backgroundColor, "the bar has no color")
        let color = try #require(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
        let bar = ThemeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: color.alphaComponent)
        let ground = backdrop(tokens)
        return over(bar, ground).contrast(with: ground)
    }

    static let picked = GroupColor.allCases

    @Test(arguments: themes) func aRestingBarIsAQuietMark(_ name: String) throws {
        for color in Self.picked {
            let (view, window, tokens) = try Self.row(name, color: color)
            defer { window.close() }
            #expect(!view.colorRail.isHidden, "\(name) \(color): the picked color shows nowhere")
            let contrast = try Self.barContrast(view, tokens)
            #expect(contrast <= Self.restMaximum, "\(name) \(color): the resting bar draws at \(contrast):1, as loud as the title")
            #expect(contrast >= Self.visibleMinimum, "\(name) \(color): the resting bar draws at \(contrast):1 and vanishes")
        }
    }

    @Test(arguments: themes) func aSelectedRowsBarIsStrongerThanAResting(_ name: String) throws {
        for color in Self.picked {
            let (rest, restWindow, tokens) = try Self.row(name, color: color)
            let (selected, selectedWindow, _) = try Self.row(name, color: color, selected: true)
            defer { restWindow.close(); selectedWindow.close() }
            let restContrast = try Self.barContrast(rest, tokens), selectedContrast = try Self.barContrast(selected, tokens)
            #expect(selectedContrast <= Self.selectedMaximum, "\(name) \(color): the selected bar draws at \(selectedContrast):1")
            #expect(selectedContrast >= restContrast, "\(name) \(color): selected \(selectedContrast):1, at rest \(restContrast):1")
        }
    }

    @Test func theBarIsAShortMarkOnTheTitlesLine() throws {
        let (view, window, _) = try Self.row("Default", color: .blue)
        defer { window.close() }
        let bar = view.colorRail.frame, font = view.title.font
        let line = ceil(font.ascender - font.descender)
        #expect(bar.height > 0 && bar.height <= line, "the bar is \(bar.height) pt tall, the title's line \(line) pt")
        // The row is flipped: the title's capitals center one half cap height above its baseline.
        let baseline = try #require(view.titlePenOrigin?.pointValue.y)
        let caps = baseline - font.capHeight / 2
        #expect(abs(bar.midY - caps) <= 1, "the bar centers at \(bar.midY), the title's capitals at \(caps)")
    }

    @Test(arguments: themes) func aRowWithNoPickedColorDrawsNoBar(_ name: String) throws {
        let (view, window, _) = try Self.row(name, color: nil)
        defer { window.close() }
        #expect(view.colorRail.isHidden || view.colorRail.superview == nil, "\(name): an uncolored row draws a bar")
        #expect(view.rowColor == nil)
    }
}
