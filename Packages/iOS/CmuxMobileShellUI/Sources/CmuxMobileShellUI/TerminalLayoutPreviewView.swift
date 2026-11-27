#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminal
import CmuxMobileTerminalKit
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
    @Environment(MobileDisplaySettings.self) private var displaySettings

    /// Workspace/session name shown in the nav bar, mirroring the real terminal
    /// screen (`WorkspaceDetailView.navigationTitle(workspace.name)`).
    private let title = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TITLE"] ?? "cmux"

    /// Background to render the terminal on. Auto-derived from the selected
    /// transcript's own dominant background (no hardcoded per-agent color), so an
    /// agent that paints its own background (OpenCode) renders seamlessly; nil for
    /// agents that use the terminal default. An explicit CMUX_UITEST_TERMINAL_BG
    /// still wins if set.
    private let backgroundHex: String?

    init() {
        let env = ProcessInfo.processInfo.environment
        let transcript = env["CMUX_UITEST_TERMINAL_TRANSCRIPT"] ?? "claude"
        let transcripts = TerminalPreviewTranscripts()
        let derived = env["CMUX_UITEST_TERMINAL_BG"]
            ?? transcripts.dominantBackgroundHex(named: transcript)
        backgroundHex = derived
        // libghostty reads CMUX_UITEST_TERMINAL_BG at runtime init (see
        // GhosttyRuntime) to set the terminal's *default* background, so unpainted
        // / reset cells match the agent's card instead of falling back to Monokai.
        // Set it here (before the surface is created) from the derived value.
        if let derived, env["CMUX_UITEST_TERMINAL_BG"] == nil {
            setenv("CMUX_UITEST_TERMINAL_BG", derived, 1)
        }
    }

    private var previewTheme: TerminalTheme {
        guard let backgroundHex,
              TerminalTheme.rgbComponents(backgroundHex) != nil else {
            return .monokai
        }
        var theme = TerminalTheme.monokai
        theme.background = backgroundHex.hasPrefix("#") ? backgroundHex : "#\(backgroundHex)"
        theme.palette[0] = theme.background
        return theme
    }

    /// Chrome (status-bar + nav-bar) fill, matching the terminal background so the
    /// header blends with the surface.
    private var chromeBackground: Color {
        previewTheme.terminalBackgroundColor
    }

    var body: some View {
        NavigationStack {
            TerminalLayoutPreviewSurface(theme: previewTheme)
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
                        // Keep this standalone DEBUG fixture independent of
                        // CoreUI's SF Symbol rasterizer. On a fresh simulator,
                        // the terminal surface can make a toolbar symbol's
                        // initial proposed size zero, which crashes CoreUI.
                        Text("‹")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    // Title on its own Liquid Glass pill so it stays legible over
                    // terminal text when the bar background is cleared (iOS 26),
                    // matching WorkspaceDetailView.glassTitle.
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(previewTheme.terminalChromeForegroundColor)
                            .mobileGlassNavigationTitle()
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Text("▣")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    if ProcessInfo.processInfo.environment["CMUX_UITEST_ALT_SCREEN_NOTICE_PREVIEW"] == "1",
                       displaySettings.showAltScreenNotice {
                        ToolbarItem(placement: .topBarTrailing) {
                            AltScreenNoticeButton {
                                displaySettings.showAltScreenNotice = false
                            }
                        }
                    }
                }
                .tint(previewTheme.terminalChromeForegroundColor)
                .mobileTerminalNavigationChrome(theme: previewTheme)
        }
    }
}

private struct TerminalLayoutPreviewSurface: UIViewRepresentable {
    let theme: TerminalTheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime.shared()
        } catch {
            let label = UILabel()
            label.numberOfLines = 0
            label.textColor = theme.terminalForegroundUIColor
            label.backgroundColor = theme.terminalBackgroundUIColor
            label.text = "runtime init failed: \(error.localizedDescription)"
            return label
        }
        let fontSize = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_FONT_SIZE"]
            .flatMap(Float32.init) ?? MobileTerminalFontPreference.defaultSize
        context.coordinator.currentFont = fontSize
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: fontSize,
            terminalTheme: theme,
            terminalConfigTheme: theme
        )
        view.autoFocusOnWindowAttach = false
        // Keyboard down by default, but keep the existing keyboard viewport
        // fixture when a UI test explicitly sets it.
        let fakeKeyboardHeight = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_HEIGHT"]
            .flatMap(Double.init)
            .map { CGFloat($0) } ?? 0
        view.debugSetKeyboardHeightForLayoutPreview(max(0, fakeKeyboardHeight))
        if ProcessInfo.processInfo.environment["CMUX_UITEST_SHOW_ZOOM"] == "1" {
            view.debugShowZoomControlOverlayForPreview()
        }
        if let inset = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TOP_INSET"]
            .flatMap(Double.init) {
            view.setTopContentInset(CGFloat(inset))
        }
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
        private let transcripts = TerminalPreviewTranscripts()
        /// `CMUX_UITEST_TERMINAL_SHARED_GRID=<cols>x<rows>`: host a shared
        /// grid of that size, as a host's size state would, with the sizing
        /// chrome, and draw a labeled box on the grid's outer cells.
        private let sharedGrid: (columns: Int, rows: Int)? = {
            guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_SHARED_GRID"] else {
                return nil
            }
            let parts = raw.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            return (parts[0], parts[1])
        }()

        private func applySharedGrid(
            _ grid: (columns: Int, rows: Int),
            to surfaceView: GhosttySurfaceView,
            natural: TerminalGridSize,
            reportID: UInt64
        ) {
            guard natural.columns > 0, natural.rows > 0 else { return }
            surfaceView.sharedSizingDecoration = TerminalSizingBoundsDecoration(
                gridColumns: grid.columns,
                gridRows: grid.rows,
                viewerColumns: natural.columns,
                viewerRows: natural.rows
            )
            let scaled = grid.columns > natural.columns || grid.rows > natural.rows
            let title = "\(grid.columns)×\(grid.rows) · Fixed" + (scaled ? " · scaled" : "")
            surfaceView.sharedSizingChip = TerminalSizingChipContent(
                title: title,
                compactTitle: "\(grid.columns)×\(grid.rows)",
                accessibilityLabel: title,
                accessibilityHint: ""
            )
            let feed = !didFeedContent
            didFeedContent = true
            Task { @MainActor [weak surfaceView] in
                guard let surfaceView else { return }
                // Draw only once the surface holds the shared grid, so the
                // box is not reflowed from the natural grid.
                _ = await surfaceView.applyViewSizeAndWait(cols: grid.columns, rows: grid.rows)
                surfaceView.markViewportReportConfirmed(reportID: reportID)
                if feed {
                    surfaceView.processOutput(Self.sharedGridBox(columns: grid.columns, rows: grid.rows))
                    // `CMUX_UITEST_TERMINAL_TOP_INSET_LATER=<pts>`: change the
                    // scroll-edge band after the scaled grid settled, as the
                    // hosted screen does when its banner lays out.
                    if let later = ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_TOP_INSET_LATER"]
                        .flatMap(Double.init) {
                        try? await ContinuousClock().sleep(for: .seconds(2))
                        surfaceView.setTopContentInset(CGFloat(later))
                    }
                }
            }
        }

        /// Scrollback lines, then a box on the outer cells of a `columns` ×
        /// `rows` grid with the row number at the start of every row. The
        /// scrollback shows whether anything above the grid leaks into view.
        static func sharedGridBox(columns: Int, rows: Int) -> Data {
            var s = ""
            for line in 1...(rows * 2) {
                s += "SCROLLBACK \(line) " + String(repeating: "#", count: 40) + "\r\n"
            }
            s += "\u{1B}[H\u{1B}[2J"
            for row in 1...rows {
                s += "\u{1B}[\(row);1H"
                if row == 1 || row == rows {
                    s += "+" + String(repeating: "-", count: max(0, columns - 2)) + "+"
                } else {
                    let label = "|\(row)"
                    s += label + "\u{1B}[\(row);\(columns)H|"
                }
            }
            s += "\u{1B}[\(rows / 2);\(max(1, columns / 2 - 6))HSIZE \(columns)x\(rows)"
            s += "\u{1B}[\(rows);2H"
            return Data(s.utf8)
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            if let grid = sharedGrid {
                applySharedGrid(grid, to: surfaceView, natural: size, reportID: reportID)
                return
            }
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
            surfaceView.processOutput(transcripts.transcript(named: transcriptName))
        }
    }
}
#endif
