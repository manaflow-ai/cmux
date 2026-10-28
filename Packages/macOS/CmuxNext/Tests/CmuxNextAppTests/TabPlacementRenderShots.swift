import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Scratch only (not landed): renders a real PaneContentView in each `tabs.barPosition`, light and
/// dark, into one PNG at the repo's artifacts/tab-placement-shots.png for the fleet step artifact.
@MainActor @Suite(.serialized) struct TabPlacementRenderShots {
    private final class Content: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            let text = "~/fun/cmux % git status\nOn branch feat-cmux-next\nnothing to commit, working tree clean\n~/fun/cmux % "
            (text as NSString).draw(at: NSPoint(x: 12, y: 10), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), .foregroundColor: NSColor.textColor])
        }
    }

    private func render(_ position: TabBarPosition, dark: Bool) -> NSImage {
        let size = NSSize(width: 720, height: 360)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let model = TabStripModel(tabs: [
            TabItem(id: TabID("a"), title: "zsh — cmux", icon: .symbol("terminal")),
            TabItem(id: TabID("b"), title: "Claude Code", icon: .symbol("sparkles")),
            TabItem(id: TabID("c"), title: "cmux.com", icon: .symbol("globe")),
            TabItem(id: TabID("d"), title: "README.md", icon: .symbol("doc.text")),
        ], selectedID: TabID("a"))
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        pane.barPosition = position
        pane.frame = window.contentLayoutRect
        let root = NSView(frame: window.contentLayoutRect)
        root.wantsLayer = true
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        root.addSubview(pane)
        window.contentView = root
        window.orderFrontRegardless()
        pane.show(Content())
        for _ in 0..<3 {
            root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(rep)
        window.orderOut(nil)
        window.close()
        return image
    }

    @Test func renderEveryPlacement() throws {
        let positions: [TabBarPosition] = [.top, .bottom, .left, .right]
        let cell = NSSize(width: 720, height: 360), label: CGFloat = 28
        let sheet = NSImage(size: NSSize(width: cell.width * 2, height: (cell.height + label) * CGFloat(positions.count)))
        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (row, position) in positions.enumerated() {
            for (column, dark) in [false, true].enumerated() {
                let y = sheet.size.height - CGFloat(row + 1) * (cell.height + label)
                render(position, dark: dark).draw(in: NSRect(x: CGFloat(column) * cell.width, y: y, width: cell.width, height: cell.height))
                let title = "tabs.barPosition = \(position.rawValue)\(position == .top ? " (default)" : "")  ·  \(dark ? "dark" : "light")"
                (title as NSString).draw(at: NSPoint(x: CGFloat(column) * cell.width + 10, y: y + cell.height + 6),
                                         withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.black])
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) { root.deleteLastPathComponent() }
        let out = root.appendingPathComponent("artifacts/tab-placement-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out)
        #expect(png.count > 10_000)
    }
}
