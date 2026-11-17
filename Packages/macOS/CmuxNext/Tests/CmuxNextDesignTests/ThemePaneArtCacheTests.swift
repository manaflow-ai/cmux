import AppKit
@testable import CmuxNextDesign
import CmuxTheme
import Foundation
import Testing

/// A theme's pane art (`appearance.paneArt.*`) at scale: many panes share the theme's few pictures through the one
/// `BackdropImageStore`, so 24 panes over 5 pictures decode 5 images, and switching themes back and forth decodes
/// nothing new. Prints `STRESS` lines with the timings (the PR's stress numbers).
@MainActor @Suite(.serialized) struct ThemePaneArtCacheTests {
    private static func pictures(_ count: Int, in folder: URL, tag: String) throws -> [BackdropSelection] {
        try (0..<count).map { index in
            let context = try #require(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(srgbRed: CGFloat(index) / CGFloat(count), green: 0.6, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            let data = try #require(NSBitmapImageRep(cgImage: try #require(context.makeImage())).representation(using: .png, properties: [:]))
            let url = folder.appending(path: "\(tag)-\(index).png")
            try data.write(to: url)
            return .file(path: url.path)
        }
    }

    @Test func manyPanesShareTheThemesFewPicturesAndSwitchesHitTheCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pane-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dark = try Self.pictures(5, in: folder, tag: "dark"), light = try Self.pictures(5, in: folder, tag: "light")
        var themed = ThemeFlourishes()
        themed.paneArt = zip(light, dark).map { BackdropSelection.pair(light: $0, dark: $1) }
        let store = BackdropImageStore(maxPixelSize: 256, snapshots: nil)
        let panes = 24

        func showAll(_ flourishes: ThemeFlourishes, dark isDark: Bool) async -> [ObjectIdentifier] {
            var shown: [ObjectIdentifier] = []
            for index in 0..<panes {
                guard let picture = flourishes.paneArt(at: index),
                      let image = await store.image(picture, dark: isDark) else { continue }
                shown.append(ObjectIdentifier(image))
            }
            return shown
        }

        let clock = ContinuousClock()
        let first = clock.now
        let darkImages = await showAll(themed, dark: true)
        let firstShow = first.duration(to: clock.now)
        #expect(darkImages.count == panes, "every pane shows a picture")
        #expect(Set(darkImages).count == 5, "24 panes over 5 pictures decode 5 images")
        let lightImages = await showAll(themed, dark: false)
        #expect(Set(lightImages).count == 5 && Set(lightImages).isDisjoint(with: Set(darkImages)))

        // 50 switches: Teal Twin dark, Teal Twin light, a plain theme (no pane art), in turn.
        var switchTimes: [Duration] = []
        for round in 0..<50 {
            let start = clock.now
            let shown: [ObjectIdentifier]
            switch round % 3 {
            case 0: shown = await showAll(themed, dark: true)
            case 1: shown = await showAll(themed, dark: false)
            default: shown = await showAll(.none, dark: true)
            }
            switchTimes.append(start.duration(to: clock.now))
            #expect(Set(shown).isSubset(of: Set(darkImages).union(lightImages)), "a switch decodes nothing new")
        }
        let sorted = switchTimes.sorted()
        let ms = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        print("STRESS pane-art first-show panes=\(panes) pictures=5 ms=\(String(format: "%.2f", ms(firstShow)))")
        print("STRESS pane-art switches=50 panes=\(panes) p50_ms=\(String(format: "%.3f", ms(sorted[25]))) p95_ms=\(String(format: "%.3f", ms(sorted[47]))) max_ms=\(String(format: "%.3f", ms(sorted[49])))")
        #expect(ms(sorted[47]) < 5, "a cached switch for 24 panes stays under 5 ms at p95")
    }

    @Test func noPaneArtCostsNothing() {
        #expect(ThemeFlourishes.none.paneArt(at: 7) == nil)
        let plan = PaneBackdropPlan.resolve(mode: .shared, own: .inherit, tint: nil,
                                            backdrop: WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 0), inheritedHasArt: false)
        #expect(plan == .none, "no theme art, shared: the pane draws nothing")
    }
}
