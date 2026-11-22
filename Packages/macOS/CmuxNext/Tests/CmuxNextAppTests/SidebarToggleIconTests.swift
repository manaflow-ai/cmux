import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-uxdr (Lawrence 2026-10-08): "i dont like sidebar toggle button icon
/// still, make more choices in debug menu, come up with better designs".
/// Every candidate draws in both sidebar states, the choice switches the
/// toggle live, the Debug menu writes the same value, and the default stays
/// the current glyph pair.
@MainActor @Suite(.serialized) struct SidebarToggleIconTests {
    private static let size = Metrics.smallIconSize

    /// The share of pixels with ink in a template image rendered at 2x.
    private static func ink(_ image: NSImage) -> (rep: NSBitmapImageRep, inked: Int)? {
        let pixels = NSSize(width: image.size.width * 2, height: image.size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { inked += 1 } }
        return (rep, inked)
    }

    @Test func everyCandidateDrawsInBothStates() throws {
        #expect(SidebarToggleIcon.allCases.count >= 7, "the current pair plus at least six new candidates")
        #expect(SidebarToggleIcon.tunable.defaultValue == .current, "the default is unchanged until Lawrence picks")
        #expect(SidebarToggleIcon.current.symbol(sidebarHidden: false) == "rectangle.lefthalf.inset.filled.arrow.left")
        #expect(SidebarToggleIcon.current.symbol(sidebarHidden: true) == "sidebar.left")
        for icon in SidebarToggleIcon.allCases {
            var drawn: [Data] = []
            for hidden in [false, true] {
                let name = icon.symbol(sidebarHidden: hidden)
                if icon.isCustom {
                    let image = try #require(SidebarToggleIcon.image(named: name, pointSize: Self.size), "\(icon) \(hidden)")
                    #expect(image.isTemplate, "\(icon) tints like an SF Symbol")
                    // As tall as a regular SF Symbol panel glyph at the toolbar size, no taller.
                    #expect(image.size.height <= Self.size * 1.2 && image.size.height >= Self.size * 0.9)
                    let (rep, inked) = try #require(Self.ink(image))
                    #expect(inked > 20, "\(icon) hidden=\(hidden) draws ink (\(inked) pixels)")
                    drawn.append(rep.tiffRepresentation ?? Data())
                } else {
                    #expect(SidebarToggleIcon.image(named: name, pointSize: Self.size) == nil)
                    #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is a system symbol")
                }
            }
            if icon.isCustom { #expect(drawn[0] != drawn[1], "\(icon): the shown and hidden forms differ") }
            #expect(!icon.tunableTitle.isEmpty)
        }
    }

    @Test func theChoiceSwitchesTheToggleLiveAndTheDebugMenuWritesIt() async throws {
        let store = TunableStore()
        store.register([SidebarToggleIcon.tunable.descriptor])
        store.activate(file: nil)
        let band = TitlebarToolbarBand(frame: .zero)
        band.iconStore = store
        band.showSidebarState(hidden: false)
        #expect(band.sidebarToggle.symbol == SidebarToggleIcon.currentCollapseSymbol)

        store.set(SidebarToggleIcon.tunable.key, SidebarToggleIcon.railFilled.tunableValue)
        try await ViewChangePermissionTests.waitUntil("the toggle took the new icon") {
            band.sidebarToggle.symbol == SidebarToggleIcon.railFilled.symbol(sidebarHidden: false)
        }
        band.showSidebarState(hidden: true)
        #expect(band.sidebarToggle.symbol == SidebarToggleIcon.railFilled.symbol(sidebarHidden: true))

        let menu = SidebarToggleIconMenu()
        menu.store = store
        let item = menu.makeItem()
        let titles = item.submenu?.items.map(\.title) ?? []
        #expect(titles.count == SidebarToggleIcon.allCases.count)
        #expect(item.submenu?.items.first { $0.state == .on }?.representedObject as? String == "railFilled")
        menu.select(.chevronPanel)
        try await ViewChangePermissionTests.waitUntil("the menu choice reached the toggle") {
            band.sidebarToggle.symbol == SidebarToggleIcon.chevronPanel.symbol(sidebarHidden: true)
        }
        menu.select(.current)
        #expect(store.override(SidebarToggleIcon.tunable.key) == nil, "choosing the default removes the override")
        try await ViewChangePermissionTests.waitUntil("back to the default") {
            band.sidebarToggle.symbol == SidebarToggleIcon.currentExpandSymbol
        }
    }

    /// Writes the review contact sheet (every candidate, light and dark,
    /// rest and hover, sidebar shown and hidden, beside traffic lights at
    /// their real size) from the app's own glyph rendering:
    /// `<package>/.build/sidebar-toggle-icons/contact-sheet.html`, and
    /// `$NX_ARTIFACTS` when set.
    @Test func writesTheContactSheet() throws {
        struct Look { let name: String; let background: NSColor; let foreground: NSColor }
        // Ghostty's default dark theme and its GitHub Light Default theme; the
        // glyph is the secondary text color, the hover pill the chrome hover fill.
        let looks = [
            Look(name: "Light", background: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                 foreground: NSColor(srgbRed: 0x1f / 255, green: 0x23 / 255, blue: 0x28 / 255, alpha: 1)),
            Look(name: "Dark", background: NSColor(srgbRed: 0x28 / 255, green: 0x2c / 255, blue: 0x34 / 255, alpha: 1),
                 foreground: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        ]
        let side = TitlebarBandButton.side
        let scale: CGFloat = 4
        func tile(_ icon: SidebarToggleIcon, hidden: Bool, look: Look, hover: Bool) -> String {
            let size = NSSize(width: 150, height: 40)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep else { return "" }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            look.background.setFill()
            NSRect(origin: .zero, size: size).fill()
            // Traffic lights: 12 pt circles, 8 pt apart, as in a macOS 26 window.
            let midY = size.height / 2
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(index) * 20, y: midY - 6, width: 12, height: 12)).fill()
            }
            let button = NSRect(x: 12 + 2 * 20 + 12 + Metrics.space3, y: midY - side / 2, width: side, height: side)
            if hover {
                look.foreground.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: button, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
            }
            let name = icon.symbol(sidebarHidden: hidden)
            let image = SidebarToggleIcon.image(named: name, pointSize: Self.size)
                ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.size, weight: .regular))
            if let image {
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    look.foreground.withAlphaComponent(hover ? 0.85 : 0.6).setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
                let fit = min(1, side / max(image.size.width, image.size.height))
                let drawn = NSSize(width: image.size.width * fit, height: image.size.height * fit)
                tinted.draw(in: NSRect(x: button.midX - drawn.width / 2, y: button.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            }
            // Back and Forward after it, for scale.
            for (index, symbol) in ["chevron.left", "chevron.right"].enumerated() {
                guard let chevron = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.size, weight: .regular)) else { continue }
                let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                    chevron.draw(in: rect)
                    look.foreground.withAlphaComponent(0.6).setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
                let x = button.maxX + Metrics.space1 + CGFloat(index) * (side + Metrics.space1)
                tinted.draw(in: NSRect(x: x + (side - chevron.size.width) / 2, y: midY - chevron.size.height / 2,
                                       width: chevron.size.width, height: chevron.size.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            let data = rep.representation(using: .png, properties: [:]) ?? Data()
            return "<img width=\"150\" height=\"40\" src=\"data:image/png;base64,\(data.base64EncodedString())\">"
        }
        var rows = ""
        for icon in SidebarToggleIcon.allCases {
            var cells = ""
            for look in looks {
                for hover in [false, true] {
                    cells += "<td>\(tile(icon, hidden: false, look: look, hover: hover))<br>\(tile(icon, hidden: true, look: look, hover: hover))</td>"
                }
            }
            let isDefault = icon == SidebarToggleIcon.tunable.defaultValue
            rows += "<tr><th><b>\(icon.tunableTitle)</b><br><code>\(icon.rawValue)</code>\(isDefault ? "<br>(default)" : "")<br><small>\(icon.isCustom ? "custom" : "SF Symbol")</small></th>\(cells)</tr>\n"
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Sidebar toggle icon candidates</title>
        <style>body{font:13px -apple-system,system-ui,sans-serif;background:#1d1f21;color:#c5c8c6;margin:24px}
        table{border-collapse:collapse}td,th{padding:8px 10px;border-bottom:1px solid #373b41;text-align:left;vertical-align:top}
        th{width:190px}img{display:block;border-radius:6px;margin:2px 0}code{color:#b5bd68}small{color:#969896}</style></head><body>
        <h1>Sidebar toggle icon candidates (cx-uxdr)</h1>
        <p>Rendered by the app's own glyph code at the toolbar icon size (\(Self.size) pt glyph, \(side) pt button), 4x.
        Each cell: top = sidebar shown, bottom = sidebar hidden. Colors: Ghostty default dark and GitHub Light Default.
        Pick one in DEV/NIGHTLY: Debug menu &gt; Sidebar Toggle Icon, or Debug Settings &gt; Sidebar and Window &gt; Sidebar toggle icon.</p>
        <table><tr><th>Candidate</th><th>Light</th><th>Light, hover</th><th>Dark</th><th>Dark, hover</th></tr>
        \(rows)</table></body></html>
        """
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = package.appending(path: ".build/sidebar-toggle-icons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: folder.appending(path: "contact-sheet.html"))
        if let artifacts = ProcessInfo.processInfo.environment["NX_ARTIFACTS"] {
            try Data(html.utf8).write(to: URL(fileURLWithPath: artifacts).appending(path: "sidebar-toggle-icons.html"))
        }
        #expect(html.contains("railFilled"))
    }
}
