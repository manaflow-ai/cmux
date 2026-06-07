#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import SwiftUI
import UIKit

/// Local repro harness for the "crash on fast zoom" bug. Mounts a single
/// `GhosttySurfaceView` and reproduces the *real* runtime conditions that
/// surround a fast pinch, since zoom alone does not crash:
///   1. Output bytes streaming into `processOutput` (as the Mac does).
///   2. The cross-device viewport feedback: `didResize` → an async
///      `applyViewSize` echo (mimicking the Mac's `mobile.terminal.viewport`
///      response), which pins an `effectiveGrid` and drives the
///      `setSurfaceSizeAtLeastGrid` letterbox-fitting path.
///   3. Rapid font zoom on a timer.
///
/// Enable with `CMUX_ZOOM_STRESS=1`; see `cmuxApp`. DEBUG-only.
public struct MobileZoomStressView: View {
    public init() {}

    public var body: some View {
        ZoomStressRepresentable()
            .ignoresSafeArea()
            .background(Color.black)
    }
}

private struct ZoomStressRepresentable: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            let label = UILabel()
            label.text = "ZoomStress: runtime init failed"
            label.textColor = .white
            return label
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: context.coordinator, fontSize: 12)
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        weak var surfaceView: GhosttySurfaceView?
        private var zoomTimer: Timer?
        private var byteTimer: Timer?
        private var grow = true
        private var lineCounter = 0

        func start() {
            // (1) Stream bytes like the Mac does, concurrently with zoom.
            // lint:allow timer — DEBUG-only crash-repro harness: the fixed wall-clock cadence IS the stress workload (hammering the output path faster than any human), so an injected virtual Clock would defeat the repro. Never compiled into release.
            byteTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.surfaceView else { return }
                    self.lineCounter += 1
                    let line = "stress line \(self.lineCounter) \u{1b}[32mgreen\u{1b}[0m and more text to wrap\r\n"
                    view.processOutput(Data(line.utf8))
                }
            }

            // (3) Hammer the zoom path far faster than a human pinch.
            // lint:allow timer — DEBUG-only crash-repro harness: the fixed wall-clock cadence IS the stress workload; an injected virtual Clock would defeat the repro. Never compiled into release.
            zoomTimer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.surfaceView else { return }
                    let direction: TerminalFontZoomDirection = self.grow ? .increase : .decrease
                    view.debugStressZoomStep(direction)
                    view.debugStressZoomStep(direction)
                    view.debugStressZoomStep(direction)
                    self.grow.toggle()
                }
            }
        }

        func stop() {
            zoomTimer?.invalidate(); zoomTimer = nil
            byteTimer?.invalidate(); byteTimer = nil
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}

        // (2) Mimic the Mac's viewport response: echo back a slightly smaller
        // grid asynchronously so an effectiveGrid is pinned and the
        // letterbox-fitting path runs, exactly like the real app's
        // didResize → updateTerminalViewport → applyViewSize cascade.
        //
        // (2b) AND emit a heavy zsh-style prompt-redraw burst on every resize.
        // On a real paired Mac each PTY resize makes zsh redraw its big
        // multi-line prompt (a few KB of escape sequences + text) on SIGWINCH —
        // that floods the output/IO path, which the trickle `byteTimer` never
        // exercises. This is the device ingredient missing from the harness:
        // the freeze reproduces on device (real zsh) but not on the
        // synthetic-content sim until the output path is loaded like this.
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
            guard size.columns > 0, size.rows > 0 else { return }
            let cols = max(1, size.columns - 3)
            let rows = max(1, size.rows - 3)
            surfaceView.processOutput(Self.promptRedrawBurst(cols: size.columns))
            Task { @MainActor [weak surfaceView] in
                surfaceView?.applyViewSize(cols: cols, rows: rows)
            }
        }

        /// A heavy, OSC-laden prompt-redraw burst mimicking real zsh with shell
        /// integration on SIGWINCH. The critical ingredient is the OSC
        /// sequences — OSC 133 (command markers), OSC 7 (cwd), OSC 0 (title),
        /// OSC 4/10/11 (colors). Each routes through the stream handler's
        /// `surfaceMessageWriter` → the 64-deep APP mailbox drained by the
        /// MAIN-thread `ghostty_app_tick`. During a zoom storm main is busy, the
        /// mailbox fills, and the `.forever` fallback push blocks
        /// `process_output` on the serial queue — the device stall the
        /// SGR-only/synthetic-content harness never reproduced. We emit well
        /// past 64 messages per burst to overflow it.
        private static func promptRedrawBurst(cols: Int) -> Data {
            var s = "\u{1b}[?2004l\r\u{1b}[0m\u{1b}[J" // reset + clear-to-end
            let cwd = "\u{1b}]7;file://mac/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-ios-swift-mobile-core/ios\u{07}"
            for i in 0..<160 {
                s += "\u{1b}]133;A\u{07}"                                   // prompt start
                s += cwd                                                    // cwd (OSC 7)
                s += "\u{1b}]0;lawrence@mac: ~/fun/cmuxterm-hq (\(i))\u{07}" // title (OSC 0)
                s += "\u{1b}]11;rgb:1d/1f/21\u{07}"                         // bg color (OSC 11)
                s += "\u{1b}]133;B\u{07}"                                   // prompt end (input start)
            }
            // A visible colored prompt line so something also renders.
            s += "\u{1b}[48;5;31m\u{1b}[38;5;15m lawrence \u{1b}[0m"
            s += "\u{1b}[48;5;236m\u{1b}[38;5;114m feat-ios-swift-mobile-core \u{1b}[0m"
            s += "\r\n\u{1b}[38;5;76m❯\u{1b}[0m \u{1b}[K"
            return Data(s.utf8)
        }
    }
}
#endif
