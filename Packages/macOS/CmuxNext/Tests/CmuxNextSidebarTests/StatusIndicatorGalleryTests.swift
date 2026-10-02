import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSidebar

/// Prototype gallery of every indicator style and state, plus the demo
/// sidebar in each style (plans/cmux-next/status-indicators.md, section
/// "Prototypes"). Runs only with `CMUX_STATUS_GALLERY=<seconds>`: it puts a
/// non-activating window on the last screen and keeps it there so a
/// screenshot can be taken with `screencapture -l <id>` (the id is written
/// to `$TMPDIR/cmux-status-gallery.windowid`).
@MainActor @Suite struct StatusIndicatorGalleryTests {
    static let states: [(String, StatusIndicatorState)] = [
        ("busy", .busy), ("40%", .busy(progress: 0.4)), ("paused", .paused(progress: 0.6)),
        ("waiting", .waiting), ("error", .error), ("done", .success),
    ]

    final class Flipped: NSView { override var isFlipped: Bool { true } }

    func label(_ text: String, _ color: NSColor, size: CGFloat = 11) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        return field
    }

    func panel(dark: Bool, slot: CGFloat, frame: NSRect) -> NSView {
        let view = Flipped(frame: frame)
        view.wantsLayer = true
        let bg = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        view.layer?.backgroundColor = bg.cgColor
        let text = dark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        let colors = StatusIndicatorLayer.Colors(
            loading: text.cgColor,
            attention: NSColor(srgbRed: 0.93, green: 0.74, blue: 0.27, alpha: 1).cgColor,
            danger: NSColor(srgbRed: 0.91, green: 0.36, blue: 0.36, alpha: 1).cgColor,
            success: NSColor(srgbRed: 0.45, green: 0.78, blue: 0.45, alpha: 1).cgColor)
        let colWidth: CGFloat = max(64, slot + 30)
        let rowHeight: CGFloat = max(30, slot + 16)
        for (c, entry) in Self.states.enumerated() {
            let l = label(entry.0, text)
            l.frame = NSRect(x: 70 + CGFloat(c) * colWidth, y: 6, width: colWidth, height: 14)
            view.addSubview(l)
        }
        for (r, style) in StatusIndicatorStyle.allCases.enumerated() {
            let y = 26 + CGFloat(r) * rowHeight
            let l = label(style.rawValue, text)
            l.frame = NSRect(x: 8, y: y + (rowHeight - 14) / 2, width: 60, height: 14)
            view.addSubview(l)
            for (c, entry) in Self.states.enumerated() {
                let indicator = StatusIndicatorLayer()
                view.layer?.addSublayer(indicator.layer)
                indicator.contentsScale = 2
                indicator.colors = colors
                indicator.frame = NSRect(x: 70 + CGFloat(c) * colWidth + 8, y: y + (rowHeight - slot) / 2, width: slot, height: slot)
                indicator.apply(.make(entry.1, style: style, animates: true), config: StatusIndicatorConfig())
            }
        }
        return view
    }

    @Test func gallery() async throws {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_STATUS_GALLERY"], let seconds = Double(raw) else { return }
        Motion.reduceMotionOverride = false
        let screen = NSScreen.screens.last ?? NSScreen.main!
        let size = NSSize(width: 1380, height: 640)
        let origin = NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - size.height - 40)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "cmux status indicator gallery"
        window.isReleasedWhenClosed = false
        let content = Flipped(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        content.addSubview(panel(dark: true, slot: 12, frame: NSRect(x: 0, y: 0, width: 480, height: 160)))
        content.addSubview(panel(dark: false, slot: 12, frame: NSRect(x: 0, y: 160, width: 480, height: 160)))
        content.addSubview(panel(dark: true, slot: 32, frame: NSRect(x: 0, y: 320, width: 480, height: 320)))
        // The demo sidebar once per style (the real rows and group headers).
        for (i, style) in StatusIndicatorStyle.allCases.enumerated() {
            let sidebar = SidebarView(model: SidebarDemoMock.makeModel())
            sidebar.frame = NSRect(x: 490 + CGFloat(i) * 222, y: 24, width: 216, height: 610)
            content.addSubview(sidebar)
            let l = label("sidebar · \(style.rawValue)", .secondaryLabelColor)
            l.frame = NSRect(x: 490 + CGFloat(i) * 222, y: 4, width: 216, height: 16)
            content.addSubview(l)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.list.setWindowVisible(true)
            for case let row in sidebar.list.subviews {
                for case let indicator as StatusIndicatorView in row.subviews {
                    indicator.configure(indicator.state, style: style)
                }
            }
        }
        window.orderFrontRegardless()
        let idFile = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-status-gallery.windowid")
        try String(window.windowNumber).write(to: idFile, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(seconds))
        window.close()
    }
}
