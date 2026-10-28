import AppKit
import CmuxTheme
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Observation
import os
import Testing

/// Settings' "Use Ghostty Config" preview follows a Ghostty config edit without a restart
/// (cx-wqn5): the host lists the page watches (`cmux.settings.host.changed`) change when the
/// config's colors do, so the preview is re-sent.
@Suite(.serialized)
struct SettingsGhosttyPreviewLiveTests {
    @Test @MainActor func aConfigEditReSendsThePreview() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let original = ThemeScope.app.store.input
        defer { ThemeScope.app.store.apply(original) }

        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = services.settingsWindow.pageHostLists() } onChange: { changed.withLock { $0 = true } }
        ThemeScope.app.store.apply(ThemeInput(background: ThemeRGB(hex: 0x203040), foreground: ThemeRGB(hex: 0xF0E0D0)))
        #expect(changed.withLock { $0 })
    }

    /// An edit only to a color no chrome token reads (`selection-foreground`) still reaches the
    /// preview.
    @Test @MainActor func anEditTokensIgnoreStillReachesThePreview() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let original = ThemeScope.app.store.input
        defer { ThemeScope.app.store.apply(original) }

        var edited = original
        edited.selectionForeground = ThemeRGB(hex: 0xFF0000)
        ThemeScope.app.store.apply(edited)
        let config = services.settingsWindow.pageHostLists()["theme"]?["config"]
        #expect(config?["selectionForeground"] == .string("#ff0000"))
    }
}

