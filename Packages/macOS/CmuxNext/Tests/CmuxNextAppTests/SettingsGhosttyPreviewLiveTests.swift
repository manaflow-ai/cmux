import AppKit
import CmuxTheme
@testable import CmuxNextApp
import CmuxNextDesign
import Observation
import Testing

/// Settings' "Use Ghostty Config" preview follows a Ghostty config edit without a restart
/// (cx-wqn5): the host lists the page watches (`cmux.settings.host.changed`) change when the
/// config's colors do, so the preview is re-sent.
@Suite(.serialized)
struct SettingsGhosttyPreviewLiveTests {
    @Test @MainActor func aConfigEditReSendsThePreview() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let original = ThemeStore.shared.input
        defer { ThemeStore.shared.apply(original) }

        let changed = Flag()
        withObservationTracking { _ = services.settingsWindow.pageHostLists() } onChange: { changed.set() }
        ThemeStore.shared.apply(ThemeInput(background: ThemeRGB(hex: 0x203040), foreground: ThemeRGB(hex: 0xF0E0D0)))
        #expect(changed.value)
    }
}

/// Set from observation's change callback.
private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}
