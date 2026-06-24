#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// DEBUG-only standalone terminal surface for screenshotting the terminal +
/// docked-toolbar layout on the simulator, with no sign-in or Mac pairing.
///
/// Mounted by the root view when ``UITestConfig/terminalLayoutPreviewEnabled``
/// is set (`CMUX_UITEST_TERMINAL_PREVIEW=1`). It renders a real libghostty
/// surface, so the toolbar position, grid reservation, and keyboard/safe-area
/// geometry are exactly what production renders.
///
/// Screenshot knobs (App Store capture):
/// - `CMUX_UITEST_TERMINAL_PREVIEW_CONTENT=1` feeds a sample agent session.
/// - `CMUX_UITEST_TERMINAL_TRANSCRIPT=claude|codex|opencode|pi` picks which one.
/// - `CMUX_UITEST_FAKE_KEYBOARD_HEIGHT=<pt>` reserves the keyboard region.
/// - `CMUX_UITEST_SCREENSHOT_KEYBOARD=1` draws a realistic iOS keyboard in that
///   region (the simulator will not render the system keyboard in CI).
struct TerminalLayoutPreviewView: View {
    /// Single source of truth for the reserved keyboard height, shared by the
    /// surface layout and the drawn-keyboard overlay. An explicit
    /// CMUX_UITEST_FAKE_KEYBOARD_HEIGHT wins (geometry tests); otherwise, when
    /// the screenshot keyboard is requested, use a device-appropriate height.
    static func effectiveKeyboardHeight() -> CGFloat {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUX_UITEST_FAKE_KEYBOARD_HEIGHT"], let v = Double(raw), v > 0 {
            return CGFloat(v)
        }
        if env["CMUX_UITEST_SCREENSHOT_KEYBOARD"] == "1" {
            let w = UIScreen.main.bounds.width
            return w >= 700 ? 384 : 322  // iPad vs iPhone portrait keyboard
        }
        return 0
    }

    private var showKeyboard: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_SCREENSHOT_KEYBOARD"] == "1"
            && Self.effectiveKeyboardHeight() > 0
    }

    var body: some View {
        TerminalLayoutPreviewSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                TerminalPalette.background
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            }
            .overlay(alignment: .bottom) {
                if showKeyboard {
                    ScreenshotKeyboardView(height: Self.effectiveKeyboardHeight())
                        .frame(height: Self.effectiveKeyboardHeight())
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)
                }
            }
            // The surface handles the keyboard itself (keyboardHeight + docked
            // toolbar); opt out of SwiftUI keyboard avoidance so the view does
            // not also shrink and double-count.
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct TerminalLayoutPreviewSurface: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime.shared()
        } catch {
            let label = UILabel()
            label.numberOfLines = 0
            label.textColor = .white
            label.text = "runtime init failed: \(error.localizedDescription)"
            return label
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: MobileTerminalFontPreference.defaultSize
        )
        view.autoFocusOnWindowAttach = false
        // The simulator refuses to render the software keyboard, so inject a
        // synthetic keyboard height to screenshot the keyboard-up layout (and 0
        // to drive the keyboard-down toggle glyph deterministically). When the
        // height is set, TerminalLayoutPreviewView overlays a drawn keyboard.
        view.debugSetKeyboardHeightForLayoutPreview(TerminalLayoutPreviewView.effectiveKeyboardHeight())
        if ProcessInfo.processInfo.environment["CMUX_UITEST_SHOW_ZOOM"] == "1" {
            view.debugShowZoomControlOverlayForPreview()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// Retained delegate (the surface holds it weakly). Feeds the selected agent
    /// transcript once the grid has real dimensions (the first `didResize`),
    /// which is the reliable signal that the surface can render output. Gated on
    /// CMUX_UITEST_TERMINAL_PREVIEW_CONTENT=1 so the blank-layout preview used by
    /// geometry tests is unchanged.
    final class Coordinator: GhosttySurfaceViewDelegate {
        private var didFeedContent = false
        private let feedContent =
            ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_PREVIEW_CONTENT"] == "1"
        private let transcriptName =
            ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TRANSCRIPT"] ?? "claude"

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
            guard feedContent, !didFeedContent, size.columns > 0, size.rows > 0 else { return }
            didFeedContent = true
            surfaceView.processOutput(TerminalPreviewTranscripts.transcript(named: transcriptName))
        }
    }
}
#endif
