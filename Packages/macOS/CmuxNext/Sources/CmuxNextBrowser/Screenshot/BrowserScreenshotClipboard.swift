public import AppKit
public import os

/// Screenshot Page and Screenshot Section's last step: the captured image goes to the clipboard; a failed capture is
/// logged.
@MainActor
public struct BrowserScreenshotClipboard {
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Copies the image `capture` takes, off the caller's turn.
    public func copy(_ capture: @escaping @MainActor () async throws -> CGImage) {
        let logger = logger
        Task {
            do {
                let image = try await capture()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
            } catch {
                logger.error("browser screenshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
