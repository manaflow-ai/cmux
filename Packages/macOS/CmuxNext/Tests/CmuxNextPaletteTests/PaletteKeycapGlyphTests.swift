import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// The palette's keycaps must draw the keys a Mac keyboard and its menus show. AppKit names Home, End,
/// Page Up, Page Down, Forward Delete and the F keys by private-use characters (NSEvent's function
/// keys), and `Shortcut.keyGlyph` drew those characters as they are: the default Palette: Page Up,
/// Page Down, First Item and Last Item rows ended in a box or nothing.
@MainActor
@Suite
struct PaletteKeycapGlyphTests {
    /// The key-equivalent character AppKit names a function key by (NSEvent's `NSHomeFunctionKey`...).
    static func key(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code)) ?? UnicodeScalar(0))) }

    /// Every key the menus name by a glyph or a word, with the glyph macOS menus draw for it.
    static let namedKeys: [(name: String, key: String, glyph: String)] = [
        ("Return", Shortcut.returnKey, "↩"), ("Tab", Shortcut.tabKey, "⇥"), ("Escape", Shortcut.escapeKey, "⎋"),
        ("Delete", Shortcut.deleteKey, "⌫"), ("Forward Delete", key(NSDeleteFunctionKey), "⌦"),
        ("Up", Shortcut.upArrowKey, "↑"), ("Down", Shortcut.downArrowKey, "↓"),
        ("Left", Shortcut.leftArrowKey, "←"), ("Right", Shortcut.rightArrowKey, "→"),
        ("Home", key(NSHomeFunctionKey), "↖"), ("End", key(NSEndFunctionKey), "↘"),
        ("Page Up", key(NSPageUpFunctionKey), "⇞"), ("Page Down", key(NSPageDownFunctionKey), "⇟"), ("Clear", key(NSClearLineFunctionKey), "⌧"),
    ]

    static let modifierGlyphs = ["⌃", "⌥", "⇧", "⌘"]

    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value) || scalar.properties.generalCategory == .control
    }

    /// Every key bound by default (the whole binding table, palette keys included) draws a keycap
    /// with no private-use or control character in it.
    @Test func everyBoundKeyDrawsAGlyph() {
        let table = RegistryKeyBindings(ActionRegistry.standard()).table
        var bad: [String] = []
        for entry in table.entries {
            for shortcut in entry.keys {
                for cap in shortcut.keycaps where cap.isEmpty || cap.unicodeScalars.contains(where: Self.isPrivateUse) {
                    bad.append("\(entry.command): key U+\(String(shortcut.key.unicodeScalars.first?.value ?? 0, radix: 16)) draws \(cap.debugDescription)")
                }
            }
        }
        #expect(bad.isEmpty, "keycaps without a glyph:\n\(Set(bad).sorted().joined(separator: "\n"))")
    }

    @Test func namedKeysDrawTheirMenuGlyphs() {
        for (name, key, glyph) in Self.namedKeys {
            #expect(Shortcut(key, modifiers: []).keyGlyph == glyph, "\(name)")
        }
        #expect(Shortcut(Self.key(NSF5FunctionKey), modifiers: []).keyGlyph == "F5")
        #expect(Shortcut(Self.key(NSF12FunctionKey), modifiers: [.command]).keycaps == ["⌘", "F12"])
        #expect(Shortcut(Self.key(NSPageUpFunctionKey), modifiers: []).searchTokens.contains("page up pgup"))
    }

    /// Draws every modifier and named key in the palette's keycaps, light and dark, into a PNG
    /// (`CMUX_KEYCAP_SNAPSHOT_PATH`, else `.build/keycap-snapshot.png` in the package), so a fleet step
    /// returns it with `cmux-ci run --artifact Packages/macOS/CmuxNext/.build/keycap-snapshot.png`.
    @Test func keycapSnapshot() throws {
        _ = NSApplication.shared
        let rows: [[String]] = [
            Self.modifierGlyphs + ["P"],
            Self.namedKeys.prefix(7).map(\.glyph),
            Self.namedKeys.dropFirst(7).map(\.glyph) + ["F5"],
            ["⇧", "⌘", "P"], ["⌃", "⌥", "⇟"], ["⌘", "↩"],
        ]
        let padding: CGFloat = 8
        var images: [(NSImage, NSPoint)] = []
        var width: CGFloat = 0
        var y = padding
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.closeAfterTest() } }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for caps in rows {
                let keys = PaletteKeycapsView()
                keys.keycaps = caps
                let size = keys.intrinsicContentSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.backgroundColor = appearance == .aqua ? .white : .black
                windows.append(window)
                let host = NSView(frame: NSRect(origin: .zero, size: size))
                window.contentView = host
                keys.frame = host.bounds
                host.addSubview(keys)
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let image = NSImage(size: size)
                image.addRepresentation(rep)
                images.append((image, NSPoint(x: padding, y: y)))
                width = max(width, size.width + padding * 2)
                y += size.height + padding
            }
        }
        let sheet = NSImage(size: NSSize(width: max(width, 200), height: y))
        sheet.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (image, origin) in images { image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1) }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = package.appendingPathComponent(".build/keycap-snapshot.png").path
        let path = ProcessInfo.processInfo.environment["CMUX_KEYCAP_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        try png.write(to: URL(fileURLWithPath: path))
    }
}
