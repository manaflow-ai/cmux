import AppKit
import CmuxTheme
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The inner-tab workspace hover card in a dark theme reads as clearly as the rich workspace card
/// beside it: its title and each tab's name draw in the theme's primary text at full strength, and
/// its paths in the theme's secondary text, not a washed-out grey on the glass (#24785 review of
/// the dark gallery capture).
@MainActor @Suite(.serialized) struct WorkspaceTabHoverCardContrastTests {
    private struct Mounted {
        let window: NSWindow
        let scope: ThemeScope
        let host: NSView
    }

    private static func mount(_ body: NSView, recolor: @escaping () -> Void) throws -> Mounted {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Tab Card Dark")), input: input, animated: false)
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
        for y in max(0, y0)..<min(rep.pixelsHigh, y1) {
            for x in max(0, Int(rect.minX * scale))..<min(rep.pixelsWide, Int(rect.maxX * scale)) {
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

    /// Each label's set color in the dark scope: the card title and tab names are the theme's
    /// primary text, paths and status the theme's secondary text, all opaque.
    @Test func theDarkInnerTabCardUsesThePrimaryAndSecondaryTextTokens() throws {
        let card = WorkspaceTabHoverCardView()
        card.configure(title: "app", tabs: [
            SidebarTab(id: TabID("t1"), title: "Claude Code", kind: .agentChat, folder: "~/Projects/cmux", state: .working),
            SidebarTab(id: TabID("t2"), title: "shell", kind: .terminal, folder: "~", state: .success),
        ])
        let mounted = try Self.mount(card) { [weak card] in card?.applyColors() }
        defer { mounted.window.close() }
        let primary = try #require(Self.rgb(mounted.scope.perform { Palette.textPrimary }))
        let secondary = try #require(Self.rgb(mounted.scope.perform { Palette.textSecondary }))
        let byText = Dictionary(Self.labels(in: card).map { ($0.stringValue, $0) }, uniquingKeysWith: { a, _ in a })
        for name in ["app", "Claude Code", "shell"] {
            let label = try #require(byText[name], "no label \(name)")
            let color = try #require(Self.rgb(label.textColor), "\(name) has no color")
            #expect(Self.same(color, primary), "\(name) draws in \(color), not the primary text \(primary)")
        }
        for path in ["~/Projects/cmux", "~"] {
            let label = try #require(byText[path], "no label \(path)")
            let color = try #require(Self.rgb(label.textColor), "\(path) has no color")
            #expect(Self.same(color, secondary), "\(path) draws in \(color), not the secondary text \(secondary)")
        }
    }

    /// On screen: the dark inner-tab card's title and tab names reach the same brightness as the
    /// rich card's title in the same theme, and its paths stay clearly readable.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func theDarkInnerTabCardIsAsBrightAsTheRichCard() throws {
        let cards = WorkspaceHoverCardGallery.cards()
        let richHost = try #require(cards.first { $0.name == "Agent idle" }?.view)
        let tabHost = try #require(cards.first { $0.name == "Inner tabs · selected" }?.view)
        var report: [String] = []
        func measure(_ host: NSView) throws -> [String: Double] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 300), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
            let scope = ThemeScope(level: .room)
            scope.setOverride(try #require(ThemeSpec("Tab Card Dark")), input: input, animated: false)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
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
            window.close()
            return out
        }
        let richInk = try measure(richHost)
        let tabInk = try measure(tabHost)
        print("TABCARD-CONTRAST \(report.joined(separator: " | "))")
        let richTitle = try #require(richInk["Fix the session hover card"])
        for name in ["app", "Claude Code", "Review changes"] {
            let ink = try #require(tabInk[name], "no \(name) label")
            #expect(ink >= richTitle * 0.9, "\(name) ink \(ink) is dimmer than the rich card title \(richTitle)")
        }
        let path = try #require(tabInk["~/Projects/cmux"])
        #expect(path >= richTitle * 0.45, "the path ink \(path) is washed out next to the title \(richTitle)")
    }
}
