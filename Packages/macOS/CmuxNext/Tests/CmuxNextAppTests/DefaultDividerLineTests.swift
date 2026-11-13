import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSettings
import Testing

extension MainPaneGutterSuites {
    /// With no `appearance.chromeStyle` in cmux.json, split panes show the same faint line the sidebar's
    /// edge shows (Leo, 2026-11-07: "if we're already showing the thin divider for the sidebar, we should
    /// by default show the thin divider for the other bits"). A style or separation chosen in the file
    /// still decides: Flat with Sidebar Line and `layout.paneSeparation` none keep them hidden.
    @MainActor struct DefaultDividerLineTests {
        final class Panes: LayoutPaneContentProvider {
            func makeContentView(for pane: PaneID) -> NSView { NSView() }
        }

        func snapshot(_ members: [String: JSONValue] = [:]) -> CmuxConfigSnapshot {
            CmuxConfigSnapshot.parse(.object(members), validDensities: SettingsApplier.validDensities,
                                     validMetrics: SettingsApplier.validMetrics)
        }

        /// Runs `body` with the file's look in the process-wide design settings, then restores them.
        func with<T>(_ file: CmuxConfigSnapshot, _ body: () throws -> T) rethrows -> T {
            let design = DesignSettings.shared
            let before = (design.chromeStyle, design.paneChrome, design.sidebarBorder)
            design.chromeStyle = file.chromeStyle
            design.setPaneChrome(file.paneChrome)
            design.sidebarBorder = file.sidebarBorder
            defer {
                design.chromeStyle = before.0
                design.setPaneChrome(before.1)
                design.sidebarBorder = before.2
            }
            return try body()
        }

        /// A chat with a right split, and the right split cut top and bottom, as the screen syncs them.
        /// Returns whether each divider draws its line at rest: (right split, right bottom split).
        func restingLines() -> (right: Bool, rightBottom: Bool) {
            _ = NSApplication.shared
            let provider = Panes()
            let root: SplitNode = .split("right", axis: .horizontal, ratio: 0.5, a: .leaf("chat"),
                                          b: .split("bottom", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("below")))
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c", width: 1, root: root)]))],
                                    activeScreenID: "s", focusedPane: "chat")
            let view = LayoutRootView(model: model, contentProvider: provider)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            defer { window.closeAfterTest() }
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let screen = view.screenViews["s"]
            let right = screen?.dividerViews[.split(SplitID("right"))]
            let bottom = screen?.dividerViews[.split(SplitID("bottom"))]
            return (right?.isLineVisible ?? false, bottom?.isLineVisible ?? false)
        }

        @Test func theDefaultLookDrawsTheSidebarsFaintLineBetweenSplitPanes() {
            let file = snapshot()
            #expect(file.chromeStyle == .flat)
            with(file) {
                #expect(Metrics.sidebarBorderWidth > 0, "the sidebar's edge shows its faint line")
                let style = LayoutStyle().applyingDesignMetrics()
                #expect(style.showsDividerLine)
                #expect(style.showsRowSeparator)
                #expect(Metrics.lineWidth(style.dividerThickness) == Metrics.sidebarBorderWidth, "as thin as the sidebar's line")
                let lines = restingLines()
                #expect(lines.right, "the right split shows its line at rest")
                #expect(lines.rightBottom, "the right bottom split shows its line at rest")
            }
        }

        /// Two strip columns and a right dock: the edge between the columns and the dock's edge draw the split's
        /// thin line at rest; the strip's last column edge parts nothing and draws none. Hovered, a column edge
        /// widens to its edge line as before.
        @Test func columnAndDockEdgesDrawTheSameFaintLineAtRest() {
            with(snapshot()) {
                _ = NSApplication.shared
                let provider = Panes()
                let layout = ScreenLayout.columns([
                    LayoutColumn(id: "c1", width: 0.4, root: .leaf("p1")),
                    LayoutColumn(id: "c2", width: 0.4, root: .leaf("p2")),
                    LayoutColumn(id: "dock", width: 0.2, root: .leaf("chat"), dock: DockColumn(edge: .right)),
                ])
                let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
                let view = LayoutRootView(model: model, contentProvider: provider)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless],
                                      backing: .buffered, defer: true)
                defer { window.closeAfterTest() }
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                let screen = view.screenViews["s"]
                let between = screen?.dividerViews[.columnEdge(ColumnID("c1"))]
                let last = screen?.dividerViews[.columnEdge(ColumnID("c2"))]
                let dock = screen?.dividerViews[.columnEdge(ColumnID("dock"))]
                #expect(between?.isLineVisible == true, "the edge between two columns shows its line at rest")
                #expect(dock?.isLineVisible == true, "the dock's edge shows its line at rest")
                #expect(last?.isLineVisible == false, "the strip's last edge parts nothing")
                if let between {
                    between.layoutSubtreeIfNeeded()
                    #expect(abs(between.lineFrameInSuperview.width - between.lineThickness) < 0.001, "as thin as a split's line")
                    between.setHovered(true)
                    between.layoutSubtreeIfNeeded()
                    #expect(between.lineFrameInSuperview.width >= LayoutStyle.columnEdgeLineThickness(dividerThickness: between.lineThickness) - 0.001)
                }
            }
        }

        @Test func aChosenStyleOrSeparationStillHidesThem() {
            let looks: [[String: JSONValue]] = [
                ["appearance": .object(["chromeStyle": .string("flat-sidebar-line")])],
                ["layout": .object(["paneSeparation": .string("none")])],
            ]
            for look in looks {
                with(snapshot(look)) {
                    #expect(!LayoutStyle().applyingDesignMetrics().showsDividerLine, "\(look)")
                    let lines = restingLines()
                    #expect(!lines.right && !lines.rightBottom, "\(look)")
                }
            }
        }
    }
}
