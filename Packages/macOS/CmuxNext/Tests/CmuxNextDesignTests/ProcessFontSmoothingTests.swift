import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// `appearance.fontSmoothing` reaches text two ways: the `AppleFontSmoothing` default AppKit reads
/// at its first text draw (``ProcessFontSmoothing/apply(_:to:)``), and the explicit context setting
/// of cmux's own glyph images (``GlyphMask``), which that default does not reach.
@Suite(.serialized) struct ProcessFontSmoothingTests {
    private let suite = "ProcessFontSmoothingTests.\(UUID().uuidString)"

    private func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: suite)) }

    /// What a missing app value gives: the Mac's global choice, else smoothing on.
    private static var globalSmooths: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[ProcessFontSmoothing.defaultsKey]
        return (global as? NSNumber).map { $0.intValue != 0 } ?? true
    }

    @Test func antialiasedWritesZeroOverAnyOtherValue() throws {
        let defaults = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: ProcessFontSmoothing.defaultsKey)
        let applied = ProcessFontSmoothing.apply(.antialiased, to: defaults)
        #expect(applied.smoothsStems == false)
        #expect(defaults.integer(forKey: ProcessFontSmoothing.defaultsKey) == 0)
        #expect(ProcessFontSmoothing(defaults: defaults) == applied, "what AppKit reads is what apply reports")
    }

    @Test func autoRemovesTheAppValueSoTheMacsChoiceApplies() throws {
        let defaults = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let auto = try #require(FontSmoothing(rawValue: "auto"))
        ProcessFontSmoothing.apply(.antialiased, to: defaults)
        let applied = ProcessFontSmoothing.apply(auto, to: defaults)
        #expect(defaults.persistentDomain(forName: suite)?[ProcessFontSmoothing.defaultsKey] == nil)
        #expect(applied.smoothsStems == Self.globalSmooths)
    }

    /// `subpixel` turns smoothing on in cmux even where the Mac turned it off for every app: the
    /// app's own value wins over the global one (measured on cmux-lawrence-2: global 0, app 2 draws
    /// the smoothed weight).
    @Test func subpixelWritesSmoothingOnOverAZero() throws {
        let defaults = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let subpixel = try #require(FontSmoothing(rawValue: "subpixel"))
        defaults.set(0, forKey: ProcessFontSmoothing.defaultsKey)
        let applied = ProcessFontSmoothing.apply(subpixel, to: defaults)
        #expect(applied.smoothsStems)
        #expect(defaults.integer(forKey: ProcessFontSmoothing.defaultsKey) != 0)
    }

    @Test func onlyZeroTurnsSmoothingOff() {
        #expect(ProcessFontSmoothing(smoothsStems: true).smoothsStems)
        guard let defaults = UserDefaults(suiteName: suite) else { Issue.record("no suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in [1, 2, 3] {
            defaults.set(value, forKey: ProcessFontSmoothing.defaultsKey)
            #expect(ProcessFontSmoothing(defaults: defaults).smoothsStems, "AppleFontSmoothing \(value)")
        }
        defaults.set(0, forKey: ProcessFontSmoothing.defaultsKey)
        #expect(ProcessFontSmoothing(defaults: defaults).smoothsStems == false)
    }

    /// The glyph image follows the value it is given: thin draws less ink than smoothed for light
    /// text (the case stem darkening thickens most). A mask that ignored it would draw chrome labels
    /// heavier than the AppKit text beside them under `antialiased`.
    @Test func glyphMaskDrawsThinnerWithoutSmoothing() {
        let ink = CGColor(srgbRed: 0.85, green: 0.87, blue: 0.95, alpha: 1)
        func coverage(_ smoothing: ProcessFontSmoothing) -> Int {
            let image = GlyphMask.image(size: CGSize(width: 220, height: 20), scale: 2, ink: ink, smoothing: smoothing) { ctx, _ in
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Workspace notes 0123", attributes: [
                    .font: NSFont.systemFont(ofSize: TypeScale.Base.body),
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: 2, y: 15)
                CTLineDraw(line, ctx)
            }
            guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
            var sum = 0
            for row in 0..<image.height {
                for column in 0..<image.width { sum += Int(bytes[row * image.bytesPerRow + column * 4 + 3]) }
            }
            return sum
        }
        let thin = coverage(ProcessFontSmoothing(smoothsStems: false))
        let smoothed = coverage(ProcessFontSmoothing(smoothsStems: true))
        #expect(thin > 0)
        // A process launched with smoothing turned off at the Core Graphics level (-AppleFontSmoothing 0)
        // draws both alike; anywhere else smoothing adds ink (about 25% for light ink at 13 pt, 2x).
        #expect(thin <= smoothed)
        if Self.globalSmooths { #expect(Double(smoothed) > Double(thin) * 1.08, "thin \(thin), smoothed \(smoothed)") }
    }
}
