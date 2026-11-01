import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// The Home split draws its divider only where it is (live-qa 2026-10-21, nightly 3a63d6d): a Home
/// column too narrow for the list's 320 pt clamps the divider to the left, and a 1 px line stayed at
/// the old 320 pt place, drawn through the see-through Chief chat (black in dark, grey in light).
///
/// NSSplitView draws each divider in a layer of its own (a sublayer whose delegate is the split view).
/// The test reads those layers' frames after the clamp and after a width set outside layout.
@MainActor
@Suite(.closesItsWindows)
struct HomeSidebarSplitDividerTests {
    /// The split's divider layers: its own sublayers, drawn by the split view (the list and the chat
    /// columns are its subviews' backing layers).
    private static func dividerFrames(_ split: HomeSidebarSplitView) -> [CGRect] {
        (split.layer?.sublayers ?? []).filter { $0.delegate === split }.map(\.frame)
    }

    /// The divider layers that draw something: shown, not transparent, wider than nothing.
    private static func drawnDividerFrames(_ split: HomeSidebarSplitView) -> [CGRect] {
        (split.layer?.sublayers ?? []).filter { $0.delegate === split && !$0.isHidden && $0.opacity > 0 }
            .map(\.frame).filter { $0.width > 0 && $0.height > 0 }
    }

    /// The list holds `conversations` Chiefs: two by default, as a list of one folds away once the
    /// clamp would leave it avatars only (`HomeLoneChiefRailTests`).
    private static func split(dark: Bool, defaults: UserDefaults, conversations: Int = 2) -> (HomeSidebarSplitView, NSWindow) {
        _ = NSApplication.shared
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        home.update(HomeLoneChiefRailTests.model(chiefs: conversations))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "divider" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = split
        split.wantsLayer = true
        split.layoutSubtreeIfNeeded()
        window.display()
        return (split, window)
    }

    private static func expectOneDivider(_ split: HomeSidebarSplitView, notAt old: CGFloat) {
        let frames = dividerFrames(split)
        #expect(!frames.isEmpty, "no divider layer")
        #expect(!frames.contains { $0.minX <= old && old < $0.maxX }, "a divider layer stays at the old \(old) pt: \(frames)")
        #expect(frames.allSatisfy { abs($0.minX - split.sidebarWidth) < 0.5 }, "divider layers \(frames), list \(split.sidebarWidth)")
    }

    @Test(arguments: [false, true])
    func aClampedDividerLeavesNoLineAtItsOldPlace(dark: Bool) throws {
        let suite = "cmux.tests.splitDivider.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (split, window) = Self.split(dark: dark, defaults: defaults)
        defer { window.close() }
        let old = split.sidebarWidth
        #expect(old == split.standard)

        // A narrow Home column: the clamp moves the divider left (a live resize, a dock that shrank).
        window.setContentSize(NSSize(width: 400, height: 300))
        split.layoutSubtreeIfNeeded()
        window.display()
        #expect(split.sidebarWidth < old - 100, "the clamp did not move the divider (\(split.sidebarWidth))")
        Self.expectOneDivider(split, notAt: old)
    }

    /// A list of one conversation folds away in the same narrow column (its divider hides with it):
    /// no line stays at the old 320 pt place either.
    @Test(arguments: [false, true])
    func aFoldedLoneConversationLeavesNoLineAtItsOldPlace(dark: Bool) throws {
        let suite = "cmux.tests.splitDividerFold.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (split, window) = Self.split(dark: dark, defaults: defaults, conversations: 1)
        defer { window.close() }
        let old = split.sidebarWidth
        #expect(old == split.standard)
        #expect(!Self.drawnDividerFrames(split).isEmpty, "no divider layer before the fold")

        window.setContentSize(NSSize(width: 400, height: 300))
        split.layoutSubtreeIfNeeded()
        window.display()
        #expect(split.sidebarWidth == 0, "the lone conversation's list did not fold (\(split.sidebarWidth) pt)")
        let drawn = Self.drawnDividerFrames(split)
        #expect(!drawn.contains { $0.minX <= old && old < $0.maxX }, "a divider layer stays at the old \(old) pt: \(drawn)")
    }

    @Test(arguments: [false, true])
    func aWidthSetOutsideLayoutMovesTheDividerLayer(dark: Bool) throws {
        let suite = "cmux.tests.splitDividerReset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (split, window) = Self.split(dark: dark, defaults: defaults)
        defer { window.close() }
        let old = split.sidebarWidth
        #if DEBUG
        split.setWidth(150)
        #endif
        split.layoutSubtreeIfNeeded()
        window.display()
        #expect(split.sidebarWidth == 150)
        Self.expectOneDivider(split, notAt: old)
        // The divider's double-click: back to the standard width.
        split.resetWidth()
        split.layoutSubtreeIfNeeded()
        window.display()
        #expect(split.sidebarWidth == old)
        Self.expectOneDivider(split, notAt: 150)
    }
}
