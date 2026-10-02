/// Bridges the production host identity snapshot into phone-push ownership.
public struct DefaultPhonePushIdentityProvider: PhonePushIdentityProvider, Sendable {
    public init() {}

    public func deviceIDIfReady() -> String? {
        MobileHostIdentity.deviceIDIfReady()
    }

    public func prewarm() async {
        await MobileHostIdentity.prewarm()
    }
}
