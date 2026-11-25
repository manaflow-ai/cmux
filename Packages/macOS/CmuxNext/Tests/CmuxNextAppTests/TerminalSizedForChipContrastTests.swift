import AppKit
import CmuxTheme
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// The "Sized for" chip takes the terminal's theme, but its Take over button drew its title for the
/// window's appearance: with the app in light appearance and a dark terminal theme, the title was dark
/// on the dark chip and could not be read (Nov 8 capture). The button now takes the theme's light or
/// dark appearance, as the chip's label and fill do.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizedForChipContrastTests {
    private struct Mounted {
        let window: NSWindow
        let scope: ThemeScope
        let chip: TerminalSizedForChip
    }

    private static func mount(themeBackground: UInt32, foreground: UInt32, window appearance: NSAppearance.Name) throws -> Mounted {
        _ = NSApplication.shared
        let input = ThemeInput(background: ThemeRGB(hex: themeBackground), foreground: ThemeRGB(hex: foreground))
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Sized For Chip")), input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        window.contentView = root
        scope.root(root)
        let chip = TerminalSizedForChip()
        chip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            chip.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])
        chip.show(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                   grid: TerminalGridSize(columns: 54, rows: 44)))
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        return Mounted(window: window, scope: scope, chip: chip)
    }

    private static func button(in chip: NSView) throws -> NSButton {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return try #require(all(chip).compactMap { $0 as? NSButton }.first)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The luminance of the button's brightest and darkest pixels in a cached drawing of the chip.
    private static func inkRange(of button: NSButton, in chip: NSView) throws -> (min: Double, max: Double) {
        let rep = try #require(chip.bitmapImageRepForCachingDisplay(in: chip.bounds))
        chip.cacheDisplay(in: chip.bounds, to: rep)
        let rect = button.convert(button.bounds, to: chip).insetBy(dx: 4, dy: 3)
        let scale = Double(rep.pixelsWide) / Double(chip.bounds.width)
        var low = 1.0, high = 0.0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                // Bitmap rows run top-down; the chip is not flipped.
                guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
                let l = 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
                low = min(low, l)
                high = max(high, l)
            }
        }
        return (low, high)
    }

    @Test func aDarkThemeInALightWindowDrawsALightTitle() throws {
        let mounted = try Self.mount(themeBackground: 0x1E1E1E, foreground: 0xD4D4D4, window: .aqua)
        defer { mounted.window.close() }
        let button = try Self.button(in: mounted.chip)
        #expect(Self.isDark(button.effectiveAppearance), "Take over draws for the window's light appearance on a dark chip")
        let ink = try Self.inkRange(of: button, in: mounted.chip)
        #expect(ink.max > 0.45, "the brightest ink in Take over is \(ink.max): its title is not readable on the dark chip")
    }

    @Test func aLightThemeInADarkWindowDrawsADarkTitle() throws {
        let mounted = try Self.mount(themeBackground: 0xFAFAFA, foreground: 0x222222, window: .darkAqua)
        defer { mounted.window.close() }
        let button = try Self.button(in: mounted.chip)
        #expect(!Self.isDark(button.effectiveAppearance), "Take over draws for the window's dark appearance on a light chip")
        let ink = try Self.inkRange(of: button, in: mounted.chip)
        #expect(ink.min < 0.4, "the darkest ink in Take over is \(ink.min): its title is not readable on the light chip")
    }
}
