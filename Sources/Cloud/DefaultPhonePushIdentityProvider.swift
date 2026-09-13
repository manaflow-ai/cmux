/// Bridges the production host identity snapshot into phone-push ownership.
struct DefaultPhonePushIdentityProvider: PhonePushIdentityProvider {
    func deviceIDIfReady() -> String? {
        MobileHostIdentity.deviceIDIfReady()
    }

    func prewarm() async {
        await MobileHostIdentity.prewarm()
    }
}
