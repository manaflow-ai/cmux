import AppKit
@testable import CmuxNextAgentPane
import CmuxNextDesign
import Testing

/// The reply menu's time header as AppKit draws it, opened for real (Leo, 2026-11-15: "why on the ellipsis
/// is the time gray? why not just have it be white like the rest"; 2026-11-16: "why is the time still
/// gray"). The first attempt (#43989) set labelColor on a disabled row, and AppKit still drew it dimmed. The
/// test opens the menu with that old row and with the new one, reads the header text's drawn color and
/// where it starts, and checks the new one against the menu's own rows. On a display step it writes the
/// two drawings side by side (old left, new right) to `menu-time-header-capture.png` at the package root,
/// for `cmux-ci run --display --artifact`.
@Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "needs a display: it opens the real menu and draws its window"))
@MainActor
struct AgentPaneMenuTimeHeaderScreenTests {
    static let time = "Today, 1:06 PM"

    @Test func theTimeDrawsInTheRowsLabelColor() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let old = try Self.capture(header: Self.disabledRowHeader())
        let new = try Self.capture(header: AgentPaneMenuTimeHeader.item(Self.time))
        print("menu-time-header old: \(old.report)\nmenu-time-header new: \(new.report)")
        if let left = old.image, let right = new.image { try Self.writeEvidence(left, right) }
        // The old disabled row's text is dimmed (why #43989 did not work).
        #expect(old.header.brightness < old.row.brightness * 0.8, "the old row was not dimmed: \(old.report)")
        // The new header's text is as bright as a row's title and starts on the same text column.
        #expect(new.header.brightness >= new.row.brightness * 0.95, "the header is dimmer than the rows: \(new.report)")
        #expect(abs(new.header.x - new.row.x) <= 1, "the header is off the rows' text column: \(new.report)")
    }

    /// #43989's header: a disabled row with a labelColor attributed title.
    static func disabledRowHeader() -> NSMenuItem {
        let item = NSMenuItem(title: time, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: time, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
        ])
        return item
    }

    /// One drawn line of text: where it starts in the menu window, and its brightest pixel (0...1).
    struct Text { var x: CGFloat; var brightness: Double }

    struct Shot {
        var image: CGImage?
        var header = Text(x: -1, brightness: -1), row = Text(x: -1, brightness: -1)
        var report = "no menu window"
    }

    /// The reply menu as the pane builds it, dark like Leo's, with `header` first; drawn from a timer that
    /// fires while it tracks, then closed.
    static func capture(header: NSMenuItem) throws -> Shot {
        let menu = NSMenu()
        let target = AgentPaneMessageTarget(text: "Done.", markdown: "Done.", replyTime: time, forkSeq: 4)
        AgentPaneContextMenu.rebuild(menu, target: target, devTools: false, scope: ThemeScope.app.fullStrength,
                                     actions: .init(copy: { _ in }, fork: { _ in }, linkItems: { _ in [] }, page: { _, _ in }))
        try #require(menu.items.first?.title == time)
        menu.removeItem(at: 0)
        menu.insertItem(header, at: 0)
        menu.appearance = NSAppearance(named: .darkAqua)
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let frame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 80, width: 40, height: 40)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        let anchor = try #require(window.contentView)
        let capture = Capture(menu, rowTitle: AgentPaneMenuStrings.copyMessage)
        let timer = Timer(timeInterval: 0.6, target: capture, selector: #selector(Capture.fire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
        timer.invalidate()
        try #require(capture.shot.image != nil, "the menu was not drawn: \(capture.shot.report)")
        return capture.shot
    }

    @MainActor final class Capture: NSObject {
        let menu: NSMenu, rowTitle: String, before: Set<ObjectIdentifier>
        var shot = Shot()

        init(_ menu: NSMenu, rowTitle: String) {
            self.menu = menu
            self.rowTitle = rowTitle
            before = Set(NSApp.windows.map(ObjectIdentifier.init))
        }

        @objc func fire(_ timer: Timer) {
            defer { menu.cancelTrackingWithoutAnimation() }
            let windows = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            shot.report = "windows: " + windows.map { String(describing: type(of: $0)) }.joined(separator: ",")
            guard let window = windows.max(by: { $0.frame.height < $1.frame.height }),
                  let root = window.contentView?.superview ?? window.contentView else { return }
            root.layoutSubtreeIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            shot.image = rep.cgImage
            let fields = AgentPaneMenuTimeHeaderScreenTests.fields(root)
            func text(_ title: String) -> Text? {
                guard let field = fields.first(where: { $0.stringValue == title }) else { return nil }
                let pad = field.cell?.titleRect(forBounds: field.bounds).minX ?? 0
                let rect = field.convert(field.bounds, to: root)
                return Text(x: rect.minX + pad, brightness: AgentPaneMenuTimeHeaderScreenTests.brightest(in: rect, of: rep, root: root))
            }
            if let header = text(AgentPaneMenuTimeHeaderScreenTests.time) { shot.header = header }
            if let row = text(rowTitle) { shot.row = row }
            let color = fields.first { $0.stringValue == AgentPaneMenuTimeHeaderScreenTests.time }?.textColor
            shot.report = "header text x \(shot.header.x) brightest \(shot.header.brightness) (field color \(color.map(String.init(describing:)) ?? "none")); "
                + "\(rowTitle) text x \(shot.row.x) brightest \(shot.row.brightness)"
        }
    }

    static func fields(_ view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
    }

    /// The brightest pixel inside `rect` (root view points) of the drawing.
    static func brightest(in rect: NSRect, of rep: NSBitmapImageRep, root: NSView) -> Double {
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        // Bitmap rows run top down; the root's points run bottom up unless it is flipped.
        let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(top * scale)), y1 = min(rep.pixelsHigh, Int((top + rect.height) * scale))
        var best = 0.0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                best = max(best, (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) * c.alphaComponent)
            }
        }
        return best
    }

    /// Old (left) and new (right) on a dark ground, at the package root on a display step, else in the
    /// temporary directory.
    static func writeEvidence(_ left: CGImage, _ right: CGImage) throws {
        let gap = 32, width = left.width + gap + right.width, height = max(left.height, right.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(left, in: CGRect(x: 0, y: height - left.height, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width + gap, y: height - right.height, width: right.width, height: right.height))
        let image = try #require(context.makeImage())
        let environment = ProcessInfo.processInfo.environment
        let onDisplayStep = environment["CMUX_CI_DISPLAY_ROUTED"] == "1" || environment["CMUX_TEST_REQUIRE_GUI"] == "1"
        // Tests/CmuxNextAgentPaneTests/<file> -> the package root.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = (onDisplayStep ? packageRoot : FileManager.default.temporaryDirectory).appending(path: "menu-time-header-capture.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        print("menu-time-header: wrote \(url.path)")
    }
}
