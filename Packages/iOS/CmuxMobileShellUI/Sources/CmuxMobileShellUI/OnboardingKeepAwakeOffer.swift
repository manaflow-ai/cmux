#if os(iOS)
import CmuxMobileShell

/// The end-of-onboarding Keep Mac Awake offer, shown on the connect scene once
/// the Mac is connected. The offer exists only while its answer can actually
/// be applied: a live foreground connection whose host advertises caffeine
/// control and whose current state is known. Anything less hides the card —
/// onboarding never shows a spinner or an inert toggle for an optional extra;
/// the computer detail keeps the full load/retry/error surface.
struct OnboardingKeepAwakeOffer: Equatable {
    let isEnabled: Bool
    let isBusy: Bool

    static func make(
        isConnected: Bool,
        isSupported: Bool,
        isEnabled: Bool?,
        isBusy: Bool
    ) -> OnboardingKeepAwakeOffer? {
        guard isConnected, isSupported, let isEnabled else { return nil }
        return OnboardingKeepAwakeOffer(isEnabled: isEnabled, isBusy: isBusy)
    }
}

/// One store adapter for every onboarding entry (first run and Settings
/// replay), so both read and mutate through the same per-pairing caffeine
/// path the Computers rows and detail use, named by the connected Mac's
/// settled identity — never an implicit "whichever Mac is active" write.
@MainActor
enum OnboardingKeepAwakeOfferSource {
    static func offer(from store: CMUXMobileShellStore?) -> OnboardingKeepAwakeOffer? {
        guard let store,
              store.connectionState == .connected,
              let macDeviceID = store.connectedMacDeviceID else { return nil }
        let instanceTag = store.connectedMacInstanceTag
        return OnboardingKeepAwakeOffer.make(
            isConnected: true,
            isSupported: store.supportsCaffeineControl(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ),
            isEnabled: store.caffeineStatus(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )?.enabled,
            isBusy: store.isCaffeineMutationInFlight(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        )
    }

    static func set(_ enabled: Bool, on store: CMUXMobileShellStore?) async -> Bool {
        guard let store,
              let macDeviceID = store.connectedMacDeviceID else { return false }
        return await store.setCaffeineEnabled(
            enabled,
            macDeviceID: macDeviceID,
            instanceTag: store.connectedMacInstanceTag
        )
    }
}
#endif
