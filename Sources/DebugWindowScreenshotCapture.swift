#if DEBUG
import AppKit
import CmuxAppKitSupportUI
import Foundation

/// App-side capture of the preferred visible app window to a PNG file, backing
/// the DEBUG-only v1 socket command `screenshot`.
///
/// The `controlDebugCaptureScreenshot` witness on ``TerminalController`` (in
/// `TerminalController+ControlDebugContext.swift`) parses the optional label,
/// builds the ``ScreenshotDestination``, creates its directory, and keeps the
/// `v2MainSync` focus-allowance scope hop the controller owns. It forwards the
/// inner main-thread work — selecting the window by the visible/largest-area
/// heuristic, rendering it via ``NSWindow/compositedDebugPNGData`` (falling back
/// to ``NSWindow/appKitDebugPNGData``), and writing the PNG — to this probe; the
/// body is the byte-faithful relocation of that block.
///
/// The window list and rendering are app-global AppKit state, not per-controller,
/// so the type holds no state and ``TerminalController`` owns one `@MainActor`
/// instance.
@MainActor
final class DebugWindowScreenshotCapture {
    /// Creates the stateless window-screenshot probe collaborator.
    init() {}

    /// Renders the preferred visible app window to a PNG at `outputPath`.
    ///
    /// Returns `nil` on success, or the verbatim legacy error description on
    /// failure (no available window, PNG rendering failure, or file-write
    /// failure) so the caller can format the `ERROR: <reason>` response exactly
    /// as the legacy `captureScreenshot` body did.
    func captureMainWindowPNG(to outputPath: URL) -> String? {
        let candidateWindows = NSApp.windows.filter { window in
            window.isVisible &&
            !window.isMiniaturized &&
            window.contentView != nil &&
            !window.frame.isEmpty
        }
        let preferredWindow = [NSApp.keyWindow, NSApp.mainWindow]
            .compactMap { $0 }
            .first { candidateWindows.contains($0) }
        let window = preferredWindow ?? candidateWindows.max { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        } ?? NSApp.mainWindow ?? NSApp.windows.first

        guard let window else {
            return "No window available"
        }

        guard let pngData = window.compositedDebugPNGData
            ?? window.appKitDebugPNGData else {
            return "Failed to create PNG data"
        }

        do {
            try pngData.write(to: outputPath)
        } catch {
            return "Failed to write file: \(error.localizedDescription)"
        }
        return nil
    }
}
#endif
