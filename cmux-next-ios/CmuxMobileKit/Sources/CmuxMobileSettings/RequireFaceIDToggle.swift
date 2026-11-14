#if os(iOS)
import CmuxMobileModel
import LocalAuthentication
import SwiftUI

/// Settings → Require Face ID. Turning it on asks for Face ID (or the
/// passcode) right away, next to the setting's own explanation, so the
/// system's Face ID prompt follows the person's tap instead of showing up
/// later on the lock screen. On an iPhone with no passcode nothing can check
/// the owner and the lock could never hold (`AppLockController.deviceOwner`
/// returns nil), so the switch stays off and says why instead of turning on
/// and doing nothing (first-user journey: `dead-button` on ios/face-id).
/// Turning it off asks nothing.
struct RequireFaceIDToggle: View {
    let settings: SettingsStore
    @State private var noPasscode = false
    @State private var checking = false
    /// Checks the owner when the setting turns on (a test replaces it).
    var confirm: @MainActor () async -> RequireFaceIDConfirmation = RequireFaceIDConfirmation.check

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.requireFaceID },
            set: { on in
                guard on else {
                    settings.requireFaceID = false
                    return
                }
                guard !checking else { return }
                checking = true
                Task { @MainActor in
                    let answer = await confirm()
                    checking = false
                    switch answer {
                    case .confirmed: settings.requireFaceID = true
                    case .noPasscode: noPasscode = true
                    case .cancelled: break
                    }
                }
            }
        )) {
            SettingsLabel("Require Face ID", symbol: "faceid")
        }
        .disabled(checking)
        .alert("Set a passcode first", isPresented: $noPasscode) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Require Face ID needs Face ID or a passcode on this iPhone. Turn one on in the Settings app, under Face ID & Passcode, then try again.")
        }
    }
}

/// What turning on Require Face ID found.
enum RequireFaceIDConfirmation: Equatable, Sendable {
    /// Face ID or the passcode checked the owner: the lock can hold.
    case confirmed
    /// The person cancelled the check: the setting stays off.
    case cancelled
    /// No Face ID and no passcode on this device: the lock could never hold.
    case noPasscode

    /// The answer for a device that can (or cannot) check its owner, and the
    /// check's result when it can.
    static func decide(canCheckOwner: Bool, passed: Bool?) -> RequireFaceIDConfirmation {
        guard canCheckOwner else { return .noPasscode }
        return passed == true ? .confirmed : .cancelled
    }

    @MainActor
    static func check() async -> RequireFaceIDConfirmation {
        let context = LAContext()
        var error: NSError?
        let can = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        guard can else { return decide(canCheckOwner: false, passed: nil) }
        let passed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on Require Face ID")) ?? false
        return decide(canCheckOwner: true, passed: passed)
    }
}
#endif
