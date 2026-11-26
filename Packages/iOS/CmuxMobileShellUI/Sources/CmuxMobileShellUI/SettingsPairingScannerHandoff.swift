import SwiftUI

/// Coordinates dismissing Settings before presenting a follow-on sheet.
///
/// SwiftUI cannot reliably present another sheet while the Settings sheet is
/// still dismissing. All Settings hosts use this owner so the handoff has one
/// state machine and one consume-on-dismiss rule. Today's follow-ons are the
/// pairing scanner and the Computers screen.
@MainActor
final class SettingsPairingScannerHandoff {
    private enum Followup {
        case pairingScanner
        case computers
    }

    private var followupAfterDismiss: Followup?

    func requestScannerAfterDismiss(isSettingsPresented: Binding<Bool>) {
        followupAfterDismiss = .pairingScanner
        isSettingsPresented.wrappedValue = false
    }

    func requestComputersAfterDismiss(isSettingsPresented: Binding<Bool>) {
        followupAfterDismiss = .computers
        isSettingsPresented.wrappedValue = false
    }

    func settingsDidDismiss(
        startScanner: (() -> Void)?,
        showComputers: (() -> Void)? = nil
    ) {
        guard let followup = followupAfterDismiss else { return }
        followupAfterDismiss = nil
        switch followup {
        case .pairingScanner:
            startScanner?()
        case .computers:
            showComputers?()
        }
    }
}
