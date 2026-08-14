#if os(iOS) && DEBUG
/// One deterministic phone-push mutation parked by the UI-test harness.
struct MobilePushPreviewPendingMutation {
    let enabled: Bool
    let continuation: CheckedContinuation<Bool, Never>
}
#endif
