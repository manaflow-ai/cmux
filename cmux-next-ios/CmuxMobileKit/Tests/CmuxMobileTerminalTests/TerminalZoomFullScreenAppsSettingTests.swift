// The projection (TerminalProjectingSession) is iOS only; this runs on the kit
// job's iOS simulator leg.
#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Settings → Terminal → Zoom Full-Screen Apps ships off (Leo, 2026-11-24:
/// "don't unilaterally MERGE ui stuff yet for now until we get better sens of
/// stuff, but having people be able to easily toggle my customieer or whatever
/// would be god"). Off, a full-screen app claims the phone's grid as before and
/// the title menu offers no Fit to Phone; on, the fit policy decides.
@MainActor
@Suite struct TerminalZoomFullScreenAppsSettingTests {
    @Test func itIsOffUntilTurnedOn() {
        let name = "TerminalZoomFullScreenAppsSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CmuxMobilePreferences.terminalZoomFullScreenApps(defaults) == false)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalZoomFullScreenApps)
        #expect(CmuxMobilePreferences.terminalZoomFullScreenApps(defaults) == true)
    }

    @Test func offKeepsTheClaimAndHidesFitToPhone() {
        TerminalFitMemory.reset()
        let mac = MacPaneMockSession(columns: 120, rows: 40, program: "htop")
        let session = TerminalProjectingSession(inner: mac, zooms: false)
        session.setClaimsSize(true)
        session.resize(columns: 54, rows: 38)
        session.start { _ in }
        #expect(session.fitsToPhone == nil, "no Fit to Phone in the title menu with the setting off")
        session.toggleFitToPhone()
        #expect(session.fitsToPhone == nil)
        #expect(mac.ptyResizes >= 1, "htop on the alternate screen claims the phone's grid at once, as before: \(mac.resizeLog)")
        session.stop()
    }
}
#endif
