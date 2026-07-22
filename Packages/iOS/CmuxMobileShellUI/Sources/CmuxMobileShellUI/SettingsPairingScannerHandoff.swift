import SwiftUI

/// Coordinates dismissing Settings before presenting the pairing scanner.
///
/// SwiftUI cannot reliably present the scanner while the Settings sheet is
/// still dismissing. All Settings hosts use this owner so the handoff has one
/// state machine and one consume-on-dismiss rule.
@MainActor
final class SettingsPairingScannerHandoff {
    private var startsScannerAfterDismiss = false

    func requestScannerAfterDismiss(isSettingsPresented: Binding<Bool>) {
        startsScannerAfterDismiss = true
        isSettingsPresented.wrappedValue = false
    }

    func settingsDidDismiss(startScanner: (() -> Void)?) {
        guard startsScannerAfterDismiss else { return }
        startsScannerAfterDismiss = false
        startScanner?()
    }
}
