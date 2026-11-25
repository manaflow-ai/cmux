import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import Testing

/// Gallery of a terminal agent's tab beside a GUI agent chat's (Leo 2026-11-24: "both of them rn are just
/// claude icon. but one is terminal one is gui"): the real tab strip, light and dark, with a Claude chat
/// (`TabIcon.agentMark`, the bare mark), Claude Code in a terminal (`TabIcon.terminalAgentMark`, the mark on a
/// soft rounded square of the tab's tint), the same pair for Codex, and a plain terminal. Written under
/// `terminal-agent-mark-gallery/` as `strip-<light|dark>.png`, bundled to `terminal-agent-mark-gallery.tar` for
/// `cmux-ci run --artifact`. Screens only; it asserts no taste. `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATerminalAgentMarkGalleryTests {
    static let size = CGSize(width: 900, height: TabStripView.preferredHeight)
    static let scale: CGFloat = 3

    static func tabs(selected: String) -> TabStripModel {
        TabStripModel(tabs: [
            TabItem(id: TabID("chat-claude"), title: "Claude chat", icon: .agentMark("claude")),
            TabItem(id: TabID("term-claude"), title: "claude (terminal)", icon: .terminalAgentMark("claude")),
            TabItem(id: TabID("chat-codex"), title: "Codex chat", icon: .agentMark("openai")),
            TabItem(id: TabID("term-codex"), title: "codex (terminal)", icon: .terminalAgentMark("openai")),
            TabItem(id: TabID("zsh"), title: "zsh", icon: .terminal),
        ], selectedID: TabID(selected))
    }

    static func render(dark: Bool, selected: String) throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        let strip = TabStripView(model: tabs(selected: selected))
        strip.dragsWindowFromEmptySpace = false
        strip.frame = root.bounds
        root.addSubview(strip)
        window.orderFrontRegardless()
        strip.windowMain.changed(isMain: true)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = root.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "terminal-agent-mark-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // `experiments.terminalAgentMark` off (the default: every agent's bare mark) and on (the rounded square).
        let before = DesignSettings.shared.terminalAgentMarks
        defer { DesignSettings.shared.terminalAgentMarks = before }
        for on in [false, true] {
            DesignSettings.shared.terminalAgentMarks = on
            for dark in [false, true] {
                for selected in ["chat-claude", "term-claude"] {
                    let image = try Self.render(dark: dark, selected: selected)
                    let name = "strip-\(on ? "on" : "off")-\(selected)-\(dark ? "dark" : "light").png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                }
            }
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "terminal-agent-mark-gallery.tar", "terminal-agent-mark-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
