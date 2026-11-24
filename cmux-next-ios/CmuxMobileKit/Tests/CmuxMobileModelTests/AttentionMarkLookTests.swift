import Foundation
import Testing
@testable import CmuxMobileModel

/// Settings → Needs You Look (the Mac's `notifications.attention.mark`): badge by default, the
/// glow only when the person picks it (Leo, 2026-11-19: a look customization, off by default).
@MainActor @Suite struct AttentionMarkLookTests {
    func defaults() -> UserDefaults {
        UserDefaults(suiteName: "attention-mark-\(UUID().uuidString)") ?? .standard
    }

    @Test func aNewInstallShowsTheBadge() {
        #expect(AttentionMarkLook.default == .badge)
        #expect(SettingsStore(defaults: defaults()).attentionMark == .badge)
    }

    @Test func theMacsValuesRead() {
        #expect(AttentionMarkLook.allCases.map(\.rawValue) == ["badge", "glow"])
        #expect(AttentionMarkLook(stored: "glow") == .glow)
        #expect(AttentionMarkLook(stored: "badge") == .badge)
        // An unknown or missing value keeps the default.
        #expect(AttentionMarkLook(stored: "sparkle") == .badge)
        #expect(AttentionMarkLook(stored: nil) == .badge)
    }

    @Test func aPickedGlowIsSavedUnderTheListsKey() {
        let store = defaults()
        let settings = SettingsStore(defaults: store)
        settings.attentionMark = .glow
        // The key the list reads (`CmuxMobilePreferences.Key.attentionMark`).
        #expect(store.string(forKey: "cmuxMobile.settings.attentionMark") == "glow")
        #expect(SettingsStore(defaults: store).attentionMark == .glow)
    }
}
