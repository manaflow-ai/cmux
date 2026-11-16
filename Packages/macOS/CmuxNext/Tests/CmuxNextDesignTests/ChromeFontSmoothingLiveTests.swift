import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/44844: a change of `appearance.fontSmoothing` while
/// the app runs reached web pages at once but not the sidebar: its text (``ChromeLabel``,
/// ``ChromeTextLayer`` through ``GlyphMask``) read the smoothing AppKit latched at launch and kept
/// its glyph images. Chrome text now follows ``ProcessFontSmoothing/chrome``, which a live change
/// (``ProcessFontSmoothing/applyLive(_:)``) moves, and draws again when it does.
@MainActor @Suite(.serialized) struct ChromeFontSmoothingLiveTests {
    private static let on = ProcessFontSmoothing(smoothsStems: true)
    private static let off = ProcessFontSmoothing(smoothsStems: false)
    /// Light ink on dark: the case stem darkening thickens most.
    private static let ink = NSColor(srgbRed: 0.85, green: 0.87, blue: 0.95, alpha: 1)
    private static let text = "Workspace notes 0123 quick brown fox"

    /// Core Graphics smooths when asked in this process: a process launched with smoothing off at the
    /// Core Graphics level (`-AppleFontSmoothing 0`) draws both alike (ProcessFontSmoothingTests).
    private static var coreGraphicsSmooths: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[ProcessFontSmoothing.defaultsKey]
        return (global as? NSNumber)?.intValue != 0
    }

    /// Runs `body` with `appearance.fontSmoothing` applied as `start` (``ProcessFontSmoothing/applyLive(_:)``
    /// writes this process's own `AppleFontSmoothing`), then puts this process's value back.
    private func withChrome(_ start: FontSmoothing, _ body: () throws -> Void) rethrows {
        let key = ProcessFontSmoothing.defaultsKey as CFString
        let saved = CFPreferencesCopyValue(key, kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: ProcessFontSmoothing.defaultsKey) } else {
                UserDefaults.standard.removeObject(forKey: ProcessFontSmoothing.defaultsKey)
            }
        }
        ProcessFontSmoothing.applyLive(start)
        try body()
    }

    private func window(with view: NSView) -> NSWindow {
        _ = NSApplication.shared // ChromeTextRefresh walks NSApp's windows
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        root.wantsLayer = true
        root.addSubview(view)
        window.contentView = root
        return window
    }

    /// The alpha sum of a glyph mask image.
    private static func coverage(_ contents: Any?) -> Int {
        guard let contents else { return 0 }
        let object = contents as CFTypeRef
        guard CFGetTypeID(object) == CGImage.typeID else { return 0 }
        let image = unsafeDowncast(object, to: CGImage.self)
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var sum = 0
        for row in 0..<image.height {
            for column in 0..<image.width { sum += Int(bytes[row * image.bytesPerRow + column * 4 + 3]) }
        }
        return sum
    }

    /// The glyph mask a ``ChromeLabel`` shows (its fill layer's mask).
    private static func labelMask(_ label: ChromeLabel) -> CALayer? {
        label.layer?.sublayers?.lazy.compactMap(\.mask).first
    }

    @Test func weightNamesTheSmoothing() {
        let ink = Self.ink.cgColor
        #expect(GlyphMask.weight(of: ink, smoothing: Self.on) != GlyphMask.weight(of: ink, smoothing: Self.off),
                "an image kept for one smoothing must never show for the other")
        #expect(GlyphMask.weight(of: ink, smoothing: Self.on) == GlyphMask.weight(of: ink, smoothing: Self.on))
    }

    @Test func chromeFollowsTheSettingWhileAppKitKeepsTheLaunchValue() {
        let launch = ProcessFontSmoothing.current
        withChrome(.subpixel) {
            #expect(ProcessFontSmoothing.chrome == Self.on)
            #expect(ProcessFontSmoothing.applyLive(.antialiased) == Self.off)
            #expect(ProcessFontSmoothing.chrome == Self.off)
            #expect(ProcessFontSmoothing.current == launch, "AppKit's launch value does not move")
        }
    }

    /// A sidebar row's subtitle: the label draws again in the new smoothing, lighter when thin.
    @Test func chromeLabelDrawsAgainOnALiveChange() {
        withChrome(.subpixel) {
            let label = ChromeLabel(labelWithString: Self.text)
            label.font = .systemFont(ofSize: TypeScale.Base.body)
            label.textColor = Self.ink
            label.frame = NSRect(x: 8, y: 30, width: 380, height: 20)
            let window = window(with: label)
            defer { window.close() }
            window.contentView?.displayIfNeeded()
            let smoothed = Self.coverage(Self.labelMask(label)?.contents)
            let draws = label.glyphDraws
            #expect(smoothed > 0)

            ProcessFontSmoothing.applyLive(.antialiased)
            #expect(label.needsDisplay, "a smoothing change marks every chrome label on screen")
            window.contentView?.displayIfNeeded()
            let thin = Self.coverage(Self.labelMask(label)?.contents)
            #expect(label.glyphDraws == draws + 1, "the glyphs draw again in the new smoothing")
            #expect(thin > 0)
            if Self.coreGraphicsSmooths { #expect(Double(smoothed) > Double(thin) * 1.05, "smoothed \(smoothed), thin \(thin)") }

            // Back: the first smoothing's image is drawn again, the same as before.
            ProcessFontSmoothing.applyLive(.subpixel)
            window.contentView?.displayIfNeeded()
            #expect(Self.coverage(Self.labelMask(label)?.contents) == smoothed)
        }
    }

    /// A sidebar row's title (``MarqueeLabel``) and a tab's title: the text layer shows the new
    /// smoothing's glyphs.
    @Test func chromeTextLayerDrawsAgainOnALiveChange() throws {
        try withChrome(.subpixel) {
            let title = MarqueeLabel(gate: Motion.sidebar, frame: NSRect(x: 8, y: 30, width: 380, height: 20))
            title.font = .systemFont(ofSize: TypeScale.Base.body)
            title.textColor = Self.ink
            title.stringValue = Self.text
            let window = window(with: title)
            defer { window.close() }
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            let text = try #require(title.layer?.sublayers?.first { $0 is ChromeTextLayer } as? ChromeTextLayer)
            let glyphs = try #require(text.sublayers?.lazy.compactMap(\.mask).first)
            text.frame = CGRect(x: 0, y: 0, width: 380, height: 20)
            glyphs.displayIfNeeded()
            let smoothed = Self.coverage(glyphs.contents)
            #expect(smoothed > 0)

            ProcessFontSmoothing.applyLive(.antialiased)
            glyphs.displayIfNeeded()
            let thin = Self.coverage(glyphs.contents)
            #expect(thin > 0)
            #expect(thin != smoothed || !Self.coreGraphicsSmooths, "the text layer still shows the launch smoothing's glyphs")
            if Self.coreGraphicsSmooths { #expect(Double(smoothed) > Double(thin) * 1.05, "smoothed \(smoothed), thin \(thin)") }
        }
    }
}
