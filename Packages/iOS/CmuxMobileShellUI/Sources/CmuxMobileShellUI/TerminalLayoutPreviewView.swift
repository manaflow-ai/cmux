#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// DEBUG-only standalone terminal surface for screenshotting the terminal +
/// docked-toolbar layout on the simulator, with no sign-in or Mac pairing.
///
/// Mounted by the root view when ``UITestConfig/terminalLayoutPreviewEnabled``
/// is set (`CMUX_UITEST_TERMINAL_PREVIEW=1`). It renders a real, blank
/// libghostty surface, so the toolbar position, grid reservation, and
/// keyboard/safe-area geometry are exactly what production renders.
struct TerminalLayoutPreviewView: View {
    var body: some View {
        TerminalLayoutPreviewSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                TerminalPalette.background
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            }
            .ignoresSafeArea(.container, edges: .bottom)
            // The surface handles the keyboard itself (keyboardHeight + docked
            // toolbar); opt out of SwiftUI keyboard avoidance so the view does
            // not also shrink and double-count.
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
        // Leave the keyboard down on first appearance; the screenshot harness
        // taps to focus when it wants the keyboard-up layout.
        view.autoFocusOnWindowAttach = false
        // The simulator refuses to render the software keyboard, so inject a
        // synthetic keyboard height to screenshot the keyboard-up layout (and 0
        // to drive the keyboard-down toggle glyph deterministically).
        let fakeHeight = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_HEIGHT"]
            .flatMap(Double.init) ?? 0
        view.debugSetKeyboardHeightForLayoutPreview(CGFloat(max(0, fakeHeight)))
        if ProcessInfo.processInfo.environment["CMUX_UITEST_SHOW_ZOOM"] == "1" {
            view.debugShowZoomControlOverlayForPreview()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// Retained delegate (the surface holds it weakly). No-op: the preview only
    /// exercises layout, not input/resize round-trips.
    final class Coordinator: GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {}
    }
}
#endif
