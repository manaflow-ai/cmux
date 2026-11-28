/// Supplies the process-stable identity to synchronous phone-push callers.
public protocol PhonePushIdentityProvider: Sendable {
    func deviceIDIfReady() -> String?
    func prewarm() async
}
