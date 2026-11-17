import AppKit
@testable import CmuxNextDesign
import Testing

/// 2026-11-16, Settings opens late: Cmd-, moved focus to the new Settings column, so the panes' strip
/// emphasis blended (ThemeScope.setEmphasis, animated). The blend settled its regions with
/// `displayIfNeeded()`, which lays out the whole window first: the half-built window (the new pane, its
/// toolbar, Home's transcript) laid out inside the key, about 18% of the key's main-thread time
/// (`sample` of 12 reopens on cmux-lawrence-2, ShellWindow.layoutIfNeeded under ThemeRepaint.apply).
/// Settling a region lays out and repaints that region only, and its `updateLayer()` colors still
/// apply before the blend reads them.
@MainActor @Suite(.serialized, .closesItsWindows) struct ThemeRepaintSettleTests {
    private final class Tinted: NSView {
        var color = NSColor.black.cgColor
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = color }
    }

    private final class Counting: NSView {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }

    /// Counts window-level layouts (cmux's ShellWindow.layoutIfNeeded in the sample).
    private final class CountingWindow: NSWindow {
        var layouts = 0
        override func layoutIfNeeded() { layouts += 1; super.layoutIfNeeded() }
    }

    private func window() -> (CountingWindow, Tinted, Counting) {
        let window = CountingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let region = Tinted(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        region.wantsLayer = true
        let other = Counting(frame: .zero)
        content.addSubview(region)
        content.addSubview(other)
        // Auto Layout, as cmux's windows use: a window with constraints lays out at window level.
        other.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            other.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 200),
            other.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            other.topAnchor.constraint(equalTo: content.topAnchor),
            other.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (window, region, other)
    }

    @Test func settlingARegionLaysOutNothingOutsideIt() {
        let (window, region, other) = window()
        defer { window.close() }
        other.layouts = 0
        window.layouts = 0
        other.needsLayout = true
        other.needsUpdateConstraints = true
        region.color = NSColor.red.cgColor
        region.needsDisplay = true
        ThemeRepaint.settle([region], views: [region])
        #expect(window.layouts == 0, "the blend ran a window-level layout")
        #expect(other.layouts == 0, "the blend laid out a view outside its region")
    }

    @Test func aSettledRegionsUpdateLayerColorIsSetBeforeTheBlendReadsIt() {
        let (window, region, _) = window()
        defer { window.close() }
        region.color = NSColor.red.cgColor
        region.needsDisplay = true
        ThemeRepaint.settle([region], views: [region])
        #expect(region.layer?.backgroundColor == NSColor.red.cgColor)
    }
}
