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
/// - `CMUX_UITEST_TERMINAL_TARGET_COLS=<n>` auto-fits the font so the terminal is
///   exactly n columns wide on any device, so a single recorded fixture fills
///   the width edge-to-edge on both iPhone and iPad.
struct TerminalLayoutPreviewView: View {
    /// Workspace/session name shown in the nav bar, mirroring the real terminal
    /// screen (`WorkspaceDetailView.navigationTitle(workspace.name)`).
    private let title = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TITLE"] ?? "cmux"

    /// Chrome (status-bar + nav-bar) fill color. Matches the libghostty default
    /// background so the header blends with the terminal. Overridable per shot
    /// via CMUX_UITEST_TERMINAL_BG (see GhosttyRuntime) so an agent rendered on a
    /// non-default background stays seamless.
    private var chromeBackground: Color {
        if let bg = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_BG"],
           let c = Color(hexString: bg.hasPrefix("#") ? bg : "#\(bg)") {
            return c
        }
        return TerminalPalette.background
    }

    var body: some View {
        NavigationStack {
            TerminalLayoutPreviewSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Fill the whole window, INCLUDING under the status bar and nav
                // bar, with the terminal color (#272822) — exactly like
                // WorkspaceDetailView. Without `.top` the header region falls back
                // to black, which does not match the running app.
                .background {
                    chromeBackground
                        .ignoresSafeArea(.container, edges: [.horizontal, .top, .bottom])
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .navigationTitle(title)
                // Match WorkspaceDetailView's terminal nav bar: a real cmux
                // titlebar (back chevron + centered name + chat/terminal icons)
                // over the translucent glass/material chrome, with the terminal
                // color showing through behind it.
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                    }
                    // Title on its own Liquid Glass pill so it stays legible over
                    // terminal text when the bar background is cleared (iOS 26),
                    // matching WorkspaceDetailView.glassTitle.
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(TerminalPalette.foreground)
                            .mobileGlassNavigationTitle()
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Image(systemName: "terminal")
                    }
                }
                .tint(TerminalPalette.foreground)
                .mobileTerminalNavigationChrome()
        }
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
        context.coordinator.currentFont = fontSize
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

    /// Retained delegate (the surface holds it weakly). Auto-fits the font to the
    /// target column count (so one fixture fills any device's width), then feeds
    /// the selected recorded agent session. Gated on
    /// CMUX_UITEST_TERMINAL_PREVIEW_CONTENT=1.
    final class Coordinator: GhosttySurfaceViewDelegate {
        var currentFont: Float32 = MobileTerminalFontPreference.defaultSize
        private var didFitFont = false
        private var didFeedContent = false
        private let feedContent =
            ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_PREVIEW_CONTENT"] == "1"
        private let transcriptName =
            ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TRANSCRIPT"] ?? "claude"
        private let targetCols =
            ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TARGET_COLS"].flatMap(Int.init)

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
            guard feedContent, size.columns > 0, size.rows > 0 else { return }

            // Auto-fit the font so the terminal is exactly `targetCols` wide.
            // cols is inversely proportional to font size; one correction lands
            // within ~1 column. Re-applying the font triggers another didResize.
            if let target = targetCols, !didFitFont, transcriptName != "probe" {
                didFitFont = true
                let newFont = (currentFont * Float32(size.columns) / Float32(target))
                    .rounded()
                let clamped = min(max(newFont, 5), 40)
                if Int(clamped) != Int(currentFont.rounded()) {
                    currentFont = clamped
                    surfaceView.setLiveFontSize(clamped)
                    return
                }
            }

            guard !didFeedContent else { return }
            didFeedContent = true

            // Grid probe: print the live cols x rows + a column ruler.
            if transcriptName == "probe" {
                var s = "iOS TERMINAL GRID: \(size.columns) cols x \(size.rows) rows\r\n\r\n"
                s += (1...size.columns).map { String($0 % 10) }.joined() + "\r\n"
                surfaceView.processOutput(Data(s.utf8))
                return
            }
            surfaceView.processOutput(TerminalPreviewTranscripts.transcript(named: transcriptName))
        }
    }
}
#endif
