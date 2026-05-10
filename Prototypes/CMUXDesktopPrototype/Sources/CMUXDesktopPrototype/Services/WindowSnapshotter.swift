import AppKit
import CoreGraphics

@MainActor
struct WindowSnapshotter {
    func snapshot(for window: HostWindow) -> NSImage? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.id,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
    }
}
