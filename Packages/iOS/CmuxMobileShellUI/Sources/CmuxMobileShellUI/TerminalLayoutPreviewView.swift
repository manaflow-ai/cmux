#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// DEBUG-only standalone terminal surface for screenshotting the terminal on the
/// simulator, with no sign-in or Mac pairing. Renders a real libghostty surface,
/// so the grid, fonts, and colors are exactly what production renders.
///
/// Screenshot knobs (App Store capture):
/// - `CMUX_UITEST_TERMINAL_PREVIEW_CONTENT=1` feeds a recorded agent session.
/// - `CMUX_UITEST_TERMINAL_TRANSCRIPT=claude|codex|opencode|pi` picks which one
///   (real captured sessions; see ``TerminalPreviewTranscripts``).
struct TerminalLayoutPreviewView: View {
    var body: some View {
        TerminalLayoutPreviewSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                TerminalPalette.background
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            }
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
        let fontSize = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_FONT_SIZE"]
            .flatMap(Float32.init) ?? MobileTerminalFontPreference.defaultSize
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: fontSize
        )
        view.autoFocusOnWindowAttach = false
        // Keyboard down: show the full terminal with the recorded session.
        view.debugSetKeyboardHeightForLayoutPreview(0)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// Retained delegate (the surface holds it weakly). Feeds the selected
    /// recorded agent session once the grid has real dimensions (the first
    /// `didResize`), which is the reliable signal that the surface can render
    /// output. Gated on CMUX_UITEST_TERMINAL_PREVIEW_CONTENT=1 so the blank
    /// layout preview used by geometry tests is unchanged.
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
            // Grid probe: print the live cols x rows + a column ruler so a single
            // screenshot reveals the exact terminal grid to record fixtures at.
            if transcriptName == "probe" {
                var s = "iOS TERMINAL GRID: \(size.columns) cols x \(size.rows) rows\r\n\r\n"
                let ruler = (1...size.columns).map { String($0 % 10) }.joined()
                s += ruler + "\r\n"
                surfaceView.processOutput(Data(s.utf8))
                return
            }
            surfaceView.processOutput(TerminalPreviewTranscripts.transcript(named: transcriptName))
        }
    }
}
#endif
