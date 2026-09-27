import AppKit
import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct CmuxAccentColorTests {
    @Test func cmuxModeUsesTheCmuxBlues() {
        let accent = CmuxAccentColor(mode: .cmux)
        #expect(rgbBytes(accent.nsColor(isDark: false)) == [0, 136, 255])
        #expect(rgbBytes(accent.nsColor(isDark: true)) == [0, 145, 255])
    }

    @Test func systemModeUsesTheResolvedControlAccent() throws {
        let accent = CmuxAccentColor(mode: .system)
        for isDark in [false, true] {
            let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
            var expected: [Int] = []
            appearance.performAsCurrentDrawingAppearance {
                expected = rgbBytes(NSColor.controlAccentColor)
            }
            #expect(!expected.isEmpty)
            #expect(rgbBytes(accent.nsColor(isDark: isDark)) == expected)
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
        for accent in CmuxAccentColorMode.allCases.map(CmuxAccentColor.init(mode:)) {
            #expect(rgbBytes(accent.nsColor(for: dark)) == rgbBytes(accent.nsColor(isDark: true)))
            #expect(rgbBytes(accent.nsColor(for: aqua)) == rgbBytes(accent.nsColor(isDark: false)))
            #expect(rgbBytes(accent.nsColor(for: nil)) == rgbBytes(accent.nsColor(isDark: false)))
        }
    }

    @Test func dynamicColorFollowsDrawingAppearance() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        let accent = CmuxAccentColor(mode: .cmux)
        var darkBytes: [Int] = []
        var lightBytes: [Int] = []
        dark.performAsCurrentDrawingAppearance {
            darkBytes = rgbBytes(accent.dynamicNSColor)
        }
        aqua.performAsCurrentDrawingAppearance {
            lightBytes = rgbBytes(accent.dynamicNSColor)
        }
        #expect(darkBytes == [0, 145, 255])
        #expect(lightBytes == [0, 136, 255])
    }

    @Test func builtInAgentStatusBlueResolvesToTheAccent() {
        for accent in CmuxAccentColorMode.allCases.map(CmuxAccentColor.init(mode:)) {
            for hex in ["#4C8DFF", "#4c8dff", " #4C8DFF "] {
                let color = accent.statusEntryColor(hex: hex, isDark: true)
                #expect(color.map(rgbBytes) == rgbBytes(accent.nsColor(isDark: true)))
            }
        }
    }

    @Test func otherStatusColorsStayAsWritten() {
        let accent = CmuxAccentColor(mode: .system)
        #expect(accent.statusEntryColor(hex: "#00FF00", isDark: false).map(rgbBytes) == [0, 255, 0])
        #expect(accent.statusEntryColor(hex: nil, isDark: false) == nil)
        #expect(accent.statusEntryColor(hex: "not-a-color", isDark: false) == nil)
    }

    @MainActor
    @Test func observerResolvesOnceAndPostsOnlyOnChange() throws {
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
        #expect(observer.current.mode == .cmux)
        #expect(observer.refresh() == false)

        defaults.set(CmuxAccentColorMode.system.rawValue, forKey: CmuxAccentColorMode.userDefaultsKey)
        #expect(observer.current.mode == .cmux)
        #expect(observer.refresh() == true)
        #expect(observer.current.mode == .system)
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
