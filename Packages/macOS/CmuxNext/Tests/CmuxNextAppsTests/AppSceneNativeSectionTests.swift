import AppKit
@testable import CmuxNextApps
import CmuxNextDesign
import Testing

/// A custom sidebar section whose data comes from a JS app (the customize app's `cmux.section/1`)
/// draws in AppKit, with the sidebar's own row tokens, so it looks like the built-in rows: no
/// SwiftUI hosting view, row heights, insets, fonts and colors from `SidebarRowTokens`, taps sent
/// back to the script, and an update op redrawing the same row view in place.
@MainActor @Suite(.serialized) struct AppSceneNativeSectionTests {
    private final class Recorder: AppSceneInteraction {
        var events: [(node: String, event: String)] = []
        func dispatch(node: String, event: String, payload: AppJSON) { events.append((node, event)) }
    }

    /// A PR list as the customize example builds it: a VStack of rows, one with a detail line.
    private static func prList() -> AppSceneModel {
        let model = AppSceneModel()
        model.apply([
            .create(id: "list", type: "VStack", props: ["spacing": 2]),
            .create(id: "each", type: "ForEach", props: [:]),
            .create(id: "r1", type: "Row", props: ["title": "Fix sidebar insets", "symbol": "arrow.triangle.pull", "onTap": true]),
            .create(id: "r2", type: "Row", props: ["title": "Native new tab page", "subtitle": "manaflow-ai/cmux #38120 · Merged",
                                                   "symbol": "checkmark.circle", "tint": "accent", "badge": "3", "onTap": true]),
            .children(id: "each", children: ["r1", "r2"]),
            .children(id: "list", children: ["each"]),
            .root(id: "list"),
        ])
        return model
    }

    private static func host(_ model: AppSceneModel, width: CGFloat = 260) -> (NSWindow, AppSceneHostingView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = AppSceneHostingView(model: model, bundleDirectory: nil)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func all(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all(in: $0) } }

    private static func row(_ title: String, in root: NSView) -> NSView? {
        all(in: root).first { $0.isAccessibilityElement() && $0.accessibilityLabel() == title }
    }

    @Test func aListSectionDrawsInAppKitWithNoSwiftUIHost() {
        let (window, root) = Self.host(Self.prList())
        defer { window.contentView = nil; window.close() }
        let hosts = Self.all(in: root).filter { NSStringFromClass(type(of: $0)).contains("NSHostingView") }
        #expect(hosts.isEmpty, "a row list renders natively, without an NSHostingView")
        #expect(Self.row("Fix sidebar insets", in: root) != nil)
        #expect(Self.row("Native new tab page", in: root) != nil)
    }

    @Test func rowsTakeTheSidebarsRowTokens() throws {
        let (window, root) = Self.host(Self.prList())
        defer { window.contentView = nil; window.close() }
        let tokens = SidebarRowTokens.current.band
        let caption = Typography.system(.default, size: tokens.captionSize, weight: .regular)
        let detailLine = ceil(NSLayoutManager().defaultLineHeight(for: caption))
        let one = try #require(Self.row("Fix sidebar insets", in: root))
        let two = try #require(Self.row("Native new tab page", in: root))
        #expect(one.frame.height == tokens.rowHeight, "a one-line row is a workspace row's height")
        #expect(two.frame.height == tokens.rowHeight + detailLine, "a row with a detail line adds that line")
        #expect(two.frame.minY - one.frame.maxY == 2, "the stack's spacing")
        #expect(root.preferredHeight(width: 260) == one.frame.height + 2 + two.frame.height)

        let labels = Self.all(in: one).compactMap { $0 as? ChromeLabel }
        let title = try #require(labels.first { $0.stringValue == "Fix sidebar insets" })
        #expect(title.font?.pointSize == tokens.titleSize)
        #expect(title.textColor == root.performWithTheme { Palette.textPrimary })
        // The text column starts where a workspace row's does: inset, icon column, the grid's gap.
        let iconColumn = max(tokens.isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox,
                             Metrics.smallIconSize + tokens.textSize.glyphStep + Metrics.space2)
        let textX = title.convert(NSPoint.zero, to: one).x
        #expect(abs(textX - (2 * tokens.horizontalInset + iconColumn + LayoutGrid.gap)) < 2.5)
    }

    @Test func tappingARowSendsTapToTheScript() throws {
        let model = Self.prList()
        let recorder = Recorder()
        model.interaction = recorder
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let row = try #require(Self.row("Native new tab page", in: root))
        #expect(row.accessibilityPerformPress())
        #expect(recorder.events.map(\.node) == ["r2"])
        #expect(recorder.events.map(\.event) == ["tap"])
    }

    @Test func anUpdateRedrawsTheSameRowViewInPlace() throws {
        let model = Self.prList()
        let (window, root) = Self.host(model)
        defer { window.contentView = nil; window.close() }
        let before = try #require(Self.row("Fix sidebar insets", in: root))
        model.apply([.update(id: "r1", props: ["title": "Fix sidebar insets (v2)"])])
        root.layoutSubtreeIfNeeded()
        let after = try #require(Self.row("Fix sidebar insets (v2)", in: root))
        #expect(after === before, "an update op reconfigures the row, it does not rebuild the section")
        model.apply([.children(id: "each", children: ["r2"]), .remove(id: "r1")])
        root.layoutSubtreeIfNeeded()
        #expect(Self.row("Fix sidebar insets (v2)", in: root) == nil)
        #expect(Self.row("Native new tab page", in: root) != nil)
    }
}
