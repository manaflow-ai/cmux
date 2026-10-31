import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The pane toolbar's ⋮ next to the sidebar's (#22972, #23003): one `OverflowButton`, so the glyph,
/// its size and the hover pill should match, with the pill as wide as each host's row of buttons.
/// Renders both at rest, hovered and pressed, and the pane's lit (zoomed), in a dark, a light and an
/// accent theme, on an opaque pane and on glass (the pane's color at 60% over
/// stripes, so a fill that hides the glass shows), into one contact sheet a fleet run returns:
/// `cmux-ci run ... --artifact Packages/macOS/CmuxNext/.build/pane-more-shots.png`. The menu's rows draw
/// only inside a menu window, so `PaneMoreOverflowButtonTests` checks that they are themed instead.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneMoreShotsTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let themes = ["Default", "Soft Blue Light", "Clay Orange"]

    static func input(_ name: String) throws -> ThemeInput {
        guard name != "Default" else { return ThemeInput.ghosttyDefault }
        let text = try String(contentsOf: repoRoot.appending(path: "Resources/cmux-themes/\(name)"), encoding: .utf8)
        let file = try #require(ThemeFileColors(name: name, themeFile: text))
        var input = ThemeInput(background: file.background, foreground: file.foreground, palette: file.palette.compactMap { $0 },
                               selectionBackground: file.selectionBackground, selectionForeground: file.selectionForeground)
        input.accentColor = file.accent
        return input
    }

    enum Look: String, CaseIterable { case rest, hover, pressed, lit }

    /// A lit control is never less visible than at rest (coord-deputy 2026-10-21: the Default theme's
    /// lit ⋮ drew the text at 40%, dimmer than the rest ink), in every bundled theme and in a light
    /// and a dark theme that name no accent.
    @Test func aLitGlyphContrastsAtLeastAsMuchAsAtRest() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.repoRoot.appending(path: "Resources/cmux-themes").path)
        var inputs = try (["Default"] + files.sorted()).map { ($0, try Self.input($0)) }
        inputs.append(("plain light", ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F), palette: [])))
        inputs.append(("plain dark", ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6), palette: [])))
        for (name, input) in inputs {
            let tokens = ThemeTokens.derive(from: input)
            let surface = tokens.windowBackground.withAlpha(1)
            let lit = tokens.litGlyph.contrast(with: surface)
            let rest = tokens.textSecondary.composited(over: surface).contrast(with: surface)
            #expect(lit >= rest, "\(name): lit \(lit) against rest \(rest)")
            // With no accent hue to tell them apart, lit must be brighter than rest, not the same grey.
            if tokens.accent == tokens.textPrimary { #expect(lit > rest, "\(name): lit \(lit) against rest \(rest)") }
        }
        // The lift keeps the theme's hue: Clay Orange's lit glyph stays orange (coord-deputy 2026-10-21).
        let clay = ThemeTokens.derive(from: try Self.input("Clay Orange")).litGlyph
        #expect(clay.red - clay.blue > 0.15, "Clay Orange lit \(clay)")
    }

    @Test func bothMoreButtonsRenderToTheContactSheet() throws {
        _ = NSApplication.shared
        let original = ThemeScope.app.store.input
        defer { _ = ThemeScope.app.store.apply(original) }
        var shots: [(String, CGImage)] = []
        for theme in Self.themes {
            for glass in [false, true] {
                let image = try Self.render(theme: theme, glass: glass)
                shots.append(("\(theme), \(glass ? "glass" : "opaque")", image))
            }
        }
        let sheet = Self.contactSheet(shots)
        let out = Self.packageRoot.appending(path: ".build/pane-more-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: sheet)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out)
        print("pane-more-shots: wrote \(out.path)")
    }

    /// One theme on one surface: a row per host (sidebar, pane) with a cell per look.
    static func render(theme: String, glass: Bool) throws -> CGImage {
        let cell: CGFloat = 44, label: CGFloat = 70
        let looks = Look.allCases
        let width = label + CGFloat(looks.count) * cell + 8
        let height = 2 * cell + 8
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        window.contentView = root
        _ = ThemeScope.app.store.apply(try input(theme))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: try input(theme), animated: false)
        scope.root(root)
        window.appearance = scope.appearance
        let paneColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }
        if glass {
            root.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
            for stripe in stride(from: CGFloat(0), to: width + height, by: 12) {
                let bar = CALayer()
                bar.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.3, alpha: 1).cgColor
                bar.frame = CGRect(x: stripe - height, y: -height, width: 5, height: height * 4)
                bar.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
                root.layer?.addSublayer(bar)
            }
            let tint = CALayer()
            tint.frame = root.bounds
            tint.backgroundColor = paneColor.withAlphaComponent(0.6).cgColor
            root.layer?.addSublayer(tint)
        } else {
            root.layer?.backgroundColor = paneColor.cgColor
        }
        let ink = scope.perform { Palette.textSecondary }
        for (index, host) in ["sidebar", "pane"].enumerated() {
            let y = height - CGFloat(index + 1) * cell
            let text = NSTextField(labelWithString: host)
            text.font = NSFont.monospacedSystemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
            text.textColor = ink
            text.frame = NSRect(x: 6, y: y + cell / 2 - 8, width: label - 8, height: 16)
            root.addSubview(text)
            for (column, look) in looks.enumerated() {
                let x = label + CGFloat(column) * cell
                if host == "sidebar" {
                    guard look != .lit else { continue }
                    let button = OverflowButton(label: "More")
                    let side = SidebarStyle.controlSize
                    button.frame = NSRect(x: x + (cell - side) / 2, y: y + (cell - side) / 2, width: side, height: side)
                    root.addSubview(button)
                    apply(look, to: button)
                } else {
                    let bar = PaneToolbarView(frame: NSRect(x: x, y: y + (cell - 30) / 2, width: cell, height: 30))
                    root.addSubview(bar)
                    bar.show(more: true, lit: look == .lit)
                    bar.reveal.setPointerInside(true)
                    // The reveal fades "⋮" in, and an offscreen fade never ends: show it revealed.
                    bar.moreButton.alphaValue = 1
                    bar.layoutSubtreeIfNeeded()
                    bar.moreButton.frame = bar.moreFrame()
                    apply(look, to: bar.moreButton)
                }
            }
        }
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        CATransaction.flush()
        return try snapshot(root)
    }

    static func apply(_ look: Look, to button: OverflowButton) {
        button.hover.state.hovering = look == .hover
        button.hover.state.pressed = look == .pressed
        button.needsDisplay = true
        button.displayIfNeeded()
    }

    /// The layer tree, so the hover pill (a layer's fill) draws; `cacheDisplay` draws views only.
    static func snapshot(_ view: NSView) throws -> CGImage {
        let scale: CGFloat = 2
        let size = view.bounds.size
        let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        try #require(view.layer).render(in: context)
        return try #require(context.makeImage())
    }

    static func contactSheet(_ shots: [(String, CGImage)]) -> CGImage {
        let gap = 24, label = 36
        let cellWidth = shots.map(\.1.width).max() ?? 0, cellHeight = (shots.map(\.1.height).max() ?? 0) + label
        let columns = 2, rows = (shots.count + columns - 1) / columns
        let width = columns * (cellWidth + gap) + gap, height = rows * (cellHeight + gap) + gap
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, shot) in shots.enumerated() {
            let column = index % columns, row = index / columns
            let x = CGFloat(gap + column * (cellWidth + gap))
            let top = CGFloat(height - gap - row * (cellHeight + gap))
            (shot.0 as NSString).draw(at: NSPoint(x: x, y: top - 26), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: TypeScale.title, weight: TypeScale.regular),
                .foregroundColor: NSColor(white: 0.85, alpha: 1),
            ])
            let image = NSImage(cgImage: shot.1, size: NSSize(width: shot.1.width, height: shot.1.height))
            image.draw(in: NSRect(x: x, y: top - CGFloat(label + shot.1.height), width: CGFloat(shot.1.width), height: CGFloat(shot.1.height)))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}
