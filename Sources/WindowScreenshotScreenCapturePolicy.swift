#if DEBUG
/// Prevents a debug screenshot from triggering Screen Recording permission UI.
struct WindowScreenshotScreenCapturePolicy {
    let currentProcessAPIAvailable: Bool
    let screenCaptureAccessGranted: Bool

    var allowsScreenCaptureKit: Bool {
        currentProcessAPIAvailable || screenCaptureAccessGranted
    }
}
#endif
