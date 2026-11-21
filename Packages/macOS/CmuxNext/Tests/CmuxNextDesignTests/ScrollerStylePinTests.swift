import CmuxNextDesign
import Foundation
import Testing

/// The app pins "Show scroll bars" to "When scrolling" before AppKit reads it (Lawrence msg 34125:
/// with a mouse attached the Home list's avatar rail kept a permanent scrollbar). The pin must win
/// over "Always" and over "Automatically" with a mouse, and keep the other launch arguments.
@Suite(.serialized)
struct ScrollerStylePinTests {
    private func withArguments(_ arguments: [String: Any], _ body: (UserDefaults) -> Void) {
        let defaults = UserDefaults(suiteName: "ScrollerStylePinTests-\(UUID().uuidString)")!
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(saved.merging(arguments) { $1 }, forName: UserDefaults.argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
        }
        body(defaults)
    }

    @Test func showScrollBarsAlwaysReadsWhenScrollingAfterThePin() {
        withArguments([ScrollerStylePin.key: "Always", "ScrollerStylePinTestsOther": "kept"]) { defaults in
            let before = ScrollerStylePin().apply(to: defaults)
            #expect(before == "Always")
            #expect(defaults.string(forKey: ScrollerStylePin.key) == ScrollerStylePin.pinnedValue)
            #expect(defaults.string(forKey: "ScrollerStylePinTestsOther") == "kept")
        }
    }

    @Test func automaticWithAMouseIsPinnedToo() {
        withArguments([:]) { defaults in
            let system = defaults.string(forKey: ScrollerStylePin.key) // nil unless this Mac sets it
            #expect(ScrollerStylePin().apply(to: defaults) == system)
            #expect(defaults.string(forKey: ScrollerStylePin.key) == ScrollerStylePin.pinnedValue)
        }
    }
}
