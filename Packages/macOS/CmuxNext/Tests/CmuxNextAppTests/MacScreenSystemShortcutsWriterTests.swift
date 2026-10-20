import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Send System Shortcuts is user-only: the Mac Screen home switch and the
/// Send Keys checkmark write it the way Settings does, refusing posted
/// (synthetic) clicks and automation runs; a person's click or an
/// accessibility press (no event in dispatch) is the user.
struct MacScreenSystemShortcutsWriterTests {
    @Test func onlyAPersonMayChangeIt() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: MacScreenSettings.systemShortcutsPath))
        let person = AppServices.systemShortcutsWriter(syntheticEvent: false, run: nil)
        #expect(person == .user && person.mayWrite(descriptor))
        let posted = AppServices.systemShortcutsWriter(syntheticEvent: true, run: nil)
        #expect(!posted.mayWrite(descriptor))
        let cli = AppServices.systemShortcutsWriter(syntheticEvent: false, run: ActionRunScope(origin: .cli, allowsViewChange: false))
        #expect(!cli.mayWrite(descriptor))
        let page = AppServices.systemShortcutsWriter(syntheticEvent: false, run: ActionRunScope(origin: .page, allowsViewChange: false))
        #expect(!page.mayWrite(descriptor))
    }
}
