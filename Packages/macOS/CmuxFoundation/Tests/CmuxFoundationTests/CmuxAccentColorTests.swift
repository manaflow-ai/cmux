import AppKit
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct CmuxAccentColorTests {
    @Test func cmuxModeUsesTheCmuxBlues() {
        #expect(rgbBytes(CmuxAccentColor.nsColor(isDark: false, mode: .cmux)) == [0, 136, 255])
        #expect(rgbBytes(CmuxAccentColor.nsColor(isDark: true, mode: .cmux)) == [0, 145, 255])
    }

    @Test func systemModeUsesTheResolvedControlAccent() throws {
        for isDark in [false, true] {
            let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
            var expected: [Int] = []
            appearance.performAsCurrentDrawingAppearance {
                expected = rgbBytes(NSColor.controlAccentColor)
            }
            #expect(!expected.isEmpty)
            #expect(rgbBytes(CmuxAccentColor.nsColor(isDark: isDark, mode: .system)) == expected)
        }
    }

    @Test func storedModeParsesAndFallsBackToCmux() throws {
        let suite = "CmuxAccentColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(CmuxAccentColorMode.stored(in: defaults) == .cmux)
        for mode in CmuxAccentColorMode.allCases {
            defaults.set(mode.rawValue, forKey: CmuxAccentColorMode.userDefaultsKey)
            #expect(CmuxAccentColorMode.stored(in: defaults) == mode)
        }
        defaults.set("purple", forKey: CmuxAccentColorMode.userDefaultsKey)
        #expect(CmuxAccentColorMode.stored(in: defaults) == .cmux)
    }

    @Test func appearanceResolvesToMatchingScheme() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        #expect(rgbBytes(CmuxAccentColor.nsColor(for: dark)) == rgbBytes(CmuxAccentColor.nsColor(isDark: true)))
        #expect(rgbBytes(CmuxAccentColor.nsColor(for: aqua)) == rgbBytes(CmuxAccentColor.nsColor(isDark: false)))
        #expect(rgbBytes(CmuxAccentColor.nsColor(for: nil)) == rgbBytes(CmuxAccentColor.nsColor(isDark: false)))
    }

    @Test func dynamicColorFollowsDrawingAppearance() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        var darkBytes: [Int] = []
        var lightBytes: [Int] = []
        dark.performAsCurrentDrawingAppearance {
            darkBytes = rgbBytes(CmuxAccentColor.dynamicNSColor)
        }
        aqua.performAsCurrentDrawingAppearance {
            lightBytes = rgbBytes(CmuxAccentColor.dynamicNSColor)
        }
        #expect(darkBytes == rgbBytes(CmuxAccentColor.nsColor(isDark: true)))
        #expect(lightBytes == rgbBytes(CmuxAccentColor.nsColor(isDark: false)))
    }

    @Test func builtInAgentStatusBlueResolvesToTheAccent() {
        for mode in CmuxAccentColorMode.allCases {
            for hex in ["#4C8DFF", "#4c8dff", " #4C8DFF "] {
                let color = CmuxAccentColor.statusEntryColor(hex: hex, isDark: true, mode: mode)
                #expect(color.map(rgbBytes) == rgbBytes(CmuxAccentColor.nsColor(isDark: true, mode: mode)))
            }
        }
    }

    @Test func otherStatusColorsStayAsWritten() {
        let green = CmuxAccentColor.statusEntryColor(hex: "#00FF00", isDark: false, mode: .system)
        #expect(green.map(rgbBytes) == [0, 255, 0])
        #expect(CmuxAccentColor.statusEntryColor(hex: nil, isDark: false, mode: .cmux) == nil)
        #expect(CmuxAccentColor.statusEntryColor(hex: "not-a-color", isDark: false, mode: .cmux) == nil)
    }

    @MainActor
    @Test func observerPostsOnlyWhenTheResolvedAccentChanges() throws {
        let suite = "CmuxAccentColorTests.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: CmuxAccentColor.didChangeNotification, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }

        let observer = CmuxAccentColorObserver(defaults: defaults, center: center)
        observer.startObserving()
        #expect(observer.refresh() == false)

        defaults.set(CmuxAccentColorMode.system.rawValue, forKey: CmuxAccentColorMode.userDefaultsKey)
        #expect(observer.refresh() == true)
        #expect(observer.refresh() == false)

        defaults.set(CmuxAccentColorMode.cmux.rawValue, forKey: CmuxAccentColorMode.userDefaultsKey)
        #expect(observer.refresh() == true)
        #expect(posts == 2)
    }

    private func rgbBytes(_ color: NSColor) -> [Int] {
        guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }
}
