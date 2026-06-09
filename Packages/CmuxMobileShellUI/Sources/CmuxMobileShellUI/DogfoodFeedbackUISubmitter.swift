#if os(iOS) && DEBUG
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminal
import UIKit

/// The UI-layer ``DogfoodFeedbackSubmitting`` implementation: gathers a chrome
/// screenshot, the visible terminal text, and the debug-log snapshot, attaches
/// the multiple-choice answers + note, and forwards to the shell's
/// `dogfood.feedback.submit` path.
///
/// It lives here (not in ``CmuxMobileShell``) because the capture primitives are
/// only reachable from the UI/terminal modules: `drawHierarchy(in:)` over the
/// app window, `GhosttySurfaceView.visibleTerminalSnapshot()`, and
/// ``MobileDebugLog``. The terminal renders blank in a UIView snapshot (it is a
/// Metal/IOSurface layer), which is exactly why the terminal *text* is sent
/// alongside the screenshot.
///
/// DEV-only; absent in release builds.
@MainActor
final class DogfoodFeedbackUISubmitter: DogfoodFeedbackSubmitting {
    private let store: CMUXMobileShellStore

    /// Creates the submitter.
    /// - Parameter store: The shell store whose `submitDogfoodFeedback` carries
    ///   the bundle to the paired Mac.
    init(store: CMUXMobileShellStore) {
        self.store = store
    }

    func submit(answers: DogfoodFeedbackAnswers) async -> Bool {
        // Snapshot the chrome window + visible terminal text on the main actor
        // first (UIKit + the bounded terminal read both want main), then hand the
        // rest to the store, which builds + sends off-main.
        let screenshot = Self.captureChromeScreenshotPNG()
        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        let (_, debugLogText) = await MobileDebugLog.shared.sink.snapshotWithCount()
        let answersJSON = try? answers.encode()
        return await store.submitDogfoodFeedback(
            text: answers.note,
            debugLogText: debugLogText,
            terminalText: terminalText,
            answersJSON: answersJSON,
            screenshotPNG: screenshot
        )
    }

    /// Render a PNG of the app's content window (chrome only; the terminal is a
    /// Metal layer and renders blank, which is why the terminal text rides along).
    ///
    /// Uses `drawHierarchy(in:afterScreenUpdates:)` on the app's key window,
    /// explicitly skipping the dogfood overlay window (so the pill/pane do not
    /// appear in the shot). `ImageRenderer` would render a SwiftUI view we hand
    /// it, not the live UIKit hierarchy, so it is the wrong tool here. Returns
    /// `nil` if no suitable app window is found or the render fails.
    private static func captureChromeScreenshotPNG() -> Data? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }
        // The app's content window is the first non-overlay window in the scene.
        // The dogfood overlay is a `DogfoodPaneWindow`, excluded here so the shot
        // is the app, not the pane.
        let appWindows = scene.windows.filter { !($0 is DogfoodPaneWindow) }
        guard let window = appWindows.first(where: { $0.isKeyWindow }) ?? appWindows.first else {
            return nil
        }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }
}
#endif
