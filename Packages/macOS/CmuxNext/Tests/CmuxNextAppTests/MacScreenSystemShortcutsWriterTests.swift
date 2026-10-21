import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextMacScreen
import CmuxNextPages
import CmuxNextSettings
import Testing

/// User-only settings (here Send System Shortcuts to the Remote Mac): any
/// in-app UI interaction is the user (mouse, keyboard or an accessibility
/// press, on Settings, the Mac Screen home switch or the Send Keys
/// checkmark); every automation path (CLI, agents, scripts, the socket,
/// other pages) is refused.
@MainActor
struct MacScreenSystemShortcutsWriterTests {
    @Test func theUIPathAcceptsAndAutomationRefuses() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: MacScreenSettings.systemShortcutsPath))
        // Mac Screen home switch and Send Keys: outside an action run, the user.
        #expect(MacScreenPages.systemShortcutsWriter(run: nil).mayWrite(descriptor))
        for origin: ActionOrigin in [.cli, .mcp, .script, .remote, .page] {
            #expect(!MacScreenPages.systemShortcutsWriter(run: ActionRunScope(origin: origin, allowsViewChange: false)).mayWrite(descriptor))
        }
        // Settings: its own page's calls are the user's with or without a recorded mouse or key
        // event (an accessibility press has none); another page is not.
        let press = PageCallContext(page: PageDescriptor.settings.id, userGesture: false)
        #expect(SettingsPageProvider.writer(press).mayWrite(descriptor))
        let other = PageCallContext(page: "cmux.cloud", userGesture: true)
        #expect(!SettingsPageProvider.writer(other).mayWrite(descriptor))
        // The control socket's settings.set from the CLI or an agent.
        #expect(!SettingWriter(.cli).mayWrite(descriptor))
    }
}
