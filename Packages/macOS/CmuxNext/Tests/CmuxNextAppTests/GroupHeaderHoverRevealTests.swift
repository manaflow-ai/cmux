import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19 (u2397): a group header's + and more buttons popped in when the
/// pointer entered the header. They fade in and out with opacity only (about 0.12 s, ease-out,
/// no slide or scale), take a click at once while fading in, and show at once under Reduce
/// Motion.
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupHeaderHoverRevealTests {
    /// A sidebar with one group on screen, its header offering + (an App that runs group actions).
    static func header() throws -> (GroupHeaderRowView, NSWindow) {
        let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.red])
        sidebar.list.onGroupEditorItem = { _, _ in }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        // Never ordered front: the fades are layer animations, added with or without a screen
        // (the AWS test hosts have none), so the test always runs.
        window.contentView?.addSubview(sidebar)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let header = try #require(sidebar.list.rowViews[.group(ids[0])] as? GroupHeaderRowView)
        // Wired again: the row was wired before the App's group actions were set.
        sidebar.list.wire(header, key: .group(ids[0]))
        try #require(header.onAdd != nil, "the header offers no +")
        header.layoutSubtreeIfNeeded()
        return (header, window)
    }

    static func buttons(_ header: GroupHeaderRowView) -> [(String, NSView)] {
        [("+", header.addButton), ("more", header.moreButton)]
    }

    /// The opacity fade on `view`, if one runs.
    static func fade(_ view: NSView) -> CABasicAnimation? {
        view.layer?.animation(forKey: "opacity") as? CABasicAnimation
    }

    /// A timing curve's two control points (a curve compares by identity).
    static func points(_ curve: CAMediaTimingFunction?) -> [Float] {
        guard let curve else { return [] }
        return (1...2).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            curve.getControlPoint(at: index, values: &point)
            return point
        }
    }

    static func hover(_ header: GroupHeaderRowView, _ on: Bool) {
        header.isHovered = on
        header.layoutSubtreeIfNeeded()
    }

    @Test
    func hoverFadesTheButtonsInAndOutWithOpacityOnly() throws {
        let (header, window) = try Self.header()
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let slots = Self.buttons(header).map { $0.1.frame }

        Self.hover(header, true)
        for ((name, view), slot) in zip(Self.buttons(header), slots) {
            #expect(!view.isHidden && view.alphaValue == 1, "the \(name) button's target opacity on hover is not 1")
            let fade = try #require(Self.fade(view), "the \(name) button popped in instead of fading in")
            #expect((fade.fromValue as? NSNumber)?.doubleValue == 0 && (fade.toValue as? NSNumber)?.doubleValue == 1)
            #expect(fade.duration > 0.1 && fade.duration < 0.15, "the \(name) fade-in takes \(fade.duration) s, not about 0.12 s")
            #expect(Self.points(fade.timingFunction) == Self.points(Motion.fadeCurve), "the \(name) fade-in is not the ease-out fade curve")
            #expect(view.frame == slot, "the \(name) button moved as it appeared")
            #expect((view.layer?.animationKeys() ?? []) == ["opacity"], "the \(name) button animates more than its opacity")
            // Clickable at once, while it is still fading in.
            let center = header.convert(NSPoint(x: view.frame.midX, y: view.frame.midY), to: header.superview)
            #expect(header.hitTest(center) === view, "the \(name) button takes no click while it fades in")
        }

        Self.hover(header, false)
        for (name, view) in Self.buttons(header) {
            #expect(!view.isHidden && view.alphaValue == 0, "the \(name) button vanished instead of fading out")
            let fade = try #require(Self.fade(view), "the \(name) button popped out instead of fading out")
            #expect(fade.duration > 0.1 && fade.duration < 0.15, "the \(name) fade-out takes \(fade.duration) s, not about 0.12 s")
        }
    }

    @Test
    func reduceMotionShowsAndHidesTheButtonsAtOnce() throws {
        let (header, window) = try Self.header()
        defer { window.close() }
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }

        Self.hover(header, true)
        for (name, view) in Self.buttons(header) {
            #expect(!view.isHidden && view.alphaValue == 1, "the \(name) button does not show on hover")
            #expect(Self.fade(view) == nil, "the \(name) button fades under Reduce Motion")
        }
        Self.hover(header, false)
        for (name, view) in Self.buttons(header) {
            #expect(view.isHidden, "the \(name) button stays under Reduce Motion")
            #expect(Self.fade(view) == nil, "the \(name) button fades under Reduce Motion")
        }
    }
}
