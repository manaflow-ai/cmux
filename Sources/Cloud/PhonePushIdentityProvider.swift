/// Supplies the process-stable identity to synchronous phone-push callers.
protocol PhonePushIdentityProvider: Sendable {
    func deviceIDIfReady() -> String?
    func prewarm() async
}
