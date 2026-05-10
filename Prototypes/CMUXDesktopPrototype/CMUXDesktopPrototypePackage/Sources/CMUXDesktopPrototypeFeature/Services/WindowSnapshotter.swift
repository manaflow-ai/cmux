import AppKit
import CoreGraphics

@MainActor
struct WindowSnapshotter {
    var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
