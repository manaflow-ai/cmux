import AppKit
import CmuxTheme
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The workspace hover card's tab list in a dark theme reads as clearly as the card around it:
/// each tab's name draws in the theme's primary text, and its path in the theme's secondary text
/// (the token the card's facts use), not a washed-out tertiary grey on the glass (review of the
/// #24785 dark capture; the list landed in #28897).
@MainActor @Suite(.serialized, .closesItsWindows) struct WorkspaceTabHoverCardContrastTests {
    private struct Mounted {
        let window: NSWindow
        let scope: ThemeScope
        let host: NSView
    }

    private static func mount(_ body: NSView, recolor: @escaping () -> Void) throws -> Mounted {
        _ = NSApplication.shared
        let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Tab Card Dark")), input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        window.contentView = root
        scope.root(root)
        let host = HoverCardGalleryHost(body: body, recolor: recolor)
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        recolor()
        for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        return Mounted(window: window, scope: scope, host: host)
    }

    private static func labels(in view: NSView) -> [ChromeLabel] {
        AANestedGroupsGalleryTests.all(view).compactMap { $0 as? ChromeLabel }.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.stringValue.isEmpty }
    }

    private static func rgb(_ color: NSColor?) -> ThemeRGB? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent),
                        alpha: Double(c.alphaComponent))
    }

    /// The strongest ink a label's text reaches on screen, as the relative luminance of its
    /// brightest pixel in a cached drawing of the card (the dark card's text is the bright part).
    private static func brightestInk(_ label: ChromeLabel, in host: NSView, rep: NSBitmapImageRep) -> Double {
        let rect = label.convert(label.bounds, to: host)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        var best = 0.0
        let y0 = Int((host.isFlipped ? rect.minY : host.bounds.height - rect.maxY) * scale)
        let y1 = Int((host.isFlipped ? rect.maxY : host.bounds.height - rect.minY) * scale)
        // A row scrolled out of the list (every tab is listed since #29980) lies outside the host: no pixels.
        let rows = max(0, y0)..<max(max(0, y0), min(rep.pixelsHigh, y1))
        let x0 = max(0, Int(rect.minX * scale))
        let columns = x0..<max(x0, min(rep.pixelsWide, Int(rect.maxX * scale)))
        for y in rows {
            for x in columns {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let lum = ThemeRGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent)).relativeLuminance
                best = max(best, lum)
            }
        }
        return best
    }

    private static func same(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        a.contrast(with: b) < 1.02 && abs(a.alpha - b.alpha) < 0.01
    }

    private static func render(_ host: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Each label's set color in the dark scope: tab names are the theme's primary text, paths
    /// the theme's secondary text.
    @Test func theDarkTabListUsesThePrimaryAndSecondaryTextTokens() throws {
        let card = WorkspaceTabHoverCardView()
        card.configure(title: "app", tabs: [
            SidebarTab(id: TabID("t1"), title: "Claude Code", kind: .agentChat, folder: "~/Projects/cmux", state: .working),
            SidebarTab(id: TabID("t2"), title: "shell", kind: .terminal, folder: "~", state: .success),
        ])
        let mounted = try Self.mount(card) { [weak card] in card?.applyColors() }
        defer { mounted.window.closeAfterTest() }
        let primary = try #require(Self.rgb(mounted.scope.perform { Palette.textPrimary }))
        let secondary = try #require(Self.rgb(mounted.scope.perform { Palette.textSecondary }))
        let byText = Dictionary(Self.labels(in: card).map { ($0.stringValue, $0) }, uniquingKeysWith: { a, _ in a })
        for name in ["Claude Code", "shell"] {
            let label = try #require(byText[name], "no label \(name)")
            let color = try #require(Self.rgb(label.textColor), "\(name) has no color")
            #expect(Self.same(color, primary), "\(name) draws in \(color), not the primary text \(primary)")
        }
        // Each tab's detail line: its folder and its status (Lawrence msg 19245).
        for path in ["~/Projects/cmux · Working", "~ · Done"] {
            let label = try #require(byText[path], "no label \(path)")
            let color = try #require(Self.rgb(label.textColor), "\(path) has no color")
            #expect(Self.same(color, secondary), "\(path) draws in \(color), not the secondary text \(secondary)")
        }
    }

    /// On screen, in the chosen gallery card: the tab names reach the brightness of the card's
    /// title, and the paths stay clearly readable beside it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func theDarkTabListIsAsBrightAsItsCard() throws {
        let cards = WorkspaceHoverCardGallery.cards()
        let host = try #require(cards.first { $0.name == "Tabs first · details collapsed · chosen" }?.view)
        var report: [String] = []
        func measure(_ host: NSView) throws -> [String: Double] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 640), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.closeAfterTest() }
            window.appearance = NSAppearance(named: .darkAqua)
            let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
            let scope = ThemeScope(level: .room)
            scope.setOverride(try #require(ThemeSpec("Tab Card Dark")), input: input, animated: false)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 640))
            window.contentView = root
            scope.root(root)
            host.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                host.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            ])
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            for view in AANestedGroupsGalleryTests.all(root) { view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded() }
            CATransaction.flush()
            let rep = try Self.render(host)
            var out: [String: Double] = [:]
            for label in Self.labels(in: host) {
                out[label.stringValue] = Self.brightestInk(label, in: host, rep: rep)
                report.append("\(label.stringValue): color=\(String(describing: Self.rgb(label.textColor))) ink=\(out[label.stringValue] ?? -1)")
            }
            return out
        }
        let inks = try measure(host)
        print("TABCARD-CONTRAST \(report.joined(separator: " | "))")
        let richTitle = try #require(inks["Review the sidebar"])
        for name in ["Claude Code", "Review changes"] {
            let ink = try #require(inks[name], "no \(name) label")
            #expect(ink >= richTitle * 0.9, "\(name) ink \(ink) is dimmer than the card title \(richTitle)")
        }
        let path = try #require(inks["~/Projects/cmux · Working"])
        #expect(path >= richTitle * 0.45, "the path ink \(path) is washed out next to the title \(richTitle)")
    }
}
