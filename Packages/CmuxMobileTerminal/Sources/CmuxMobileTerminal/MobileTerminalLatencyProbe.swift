#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileGhosttyEngine
import CmuxMobileTerminalKit
import OSLog
import SwiftUI
import UIKit

private let probeLog = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.latencyProbe")

/// Self-driving typing-latency + render-cadence measurement harness for the
/// `GhosttySurfaceView` engine-actor refactor
/// (https://github.com/manaflow-ai/cmux/issues/5373).
///
/// Mounts a single `GhosttySurfaceView` whose delegate echoes produced input
/// straight back into `processOutput` — a zero-network stand-in for the Mac
/// echo — so the measured path is exactly the on-device pipeline the refactor
/// touches: input proxy → byte ingestion queue → blocking
/// `ghostty_surface_process_output` → main-actor hop → display link →
/// `ghostty_surface_render_now`.
///
/// Enable with `CMUX_LATENCY_PROBE=1` (see `CMUXMobileRootScene`). The run is
/// configured by environment variables and writes a
/// ``MobileTerminalLatencyReport`` JSON when done:
/// - `CMUX_LATENCY_REPORT_PATH` — output path (on the simulator this is a
///   host path; defaults to `/tmp/cmux-ios-latency.json`).
/// - `CMUX_LATENCY_SAMPLES` — typing keystrokes to measure (default 120).
/// - `CMUX_LATENCY_CADENCE_SECONDS` — streaming cadence window (default 8).
/// - `CMUX_LATENCY_PROBE_LABEL` — free-form run label (e.g. "baseline").
///
/// Driven by `scripts/measure-ios-terminal-latency.sh` via `simctl`. DEBUG-only.
public struct MobileTerminalLatencyProbeView: View {
    private let engineProvider: GhosttyEngineProvider

    /// Creates the probe view over the injected engine provider.
    public init(engineProvider: GhosttyEngineProvider) {
        self.engineProvider = engineProvider
    }

    /// Mounts the probe's surface host full-bleed on a black backdrop.
    public var body: some View {
        LatencyProbeRepresentable(engineProvider: engineProvider)
            .ignoresSafeArea()
            .background(Color.black)
    }
}

private struct LatencyProbeRepresentable: UIViewRepresentable {
    let engineProvider: GhosttyEngineProvider

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        guard let engine = try? engineProvider.engine() else {
            let label = UILabel()
            label.text = "LatencyProbe: runtime init failed"
            label.textColor = .white
            return label
        }
        let view = GhosttySurfaceView(engine: engine, delegate: context.coordinator, fontSize: 12)
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Drives the two measurement phases and acts as the surface's delegate,
    /// echoing produced input back as output (the local stand-in for the Mac).
    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        weak var surfaceView: GhosttySurfaceView?
        private var probeTask: Task<Void, Never>?

        // MARK: Cadence phase state (mutated only on the main actor)
        private var cadenceLink: CADisplayLink?
        private var cadenceTimestamps: [CFTimeInterval] = []
        private var cadenceDeadlineSeconds: Double = 8
        private var cadenceLineNumber = 0
        private var cadenceCompletion: CheckedContinuation<Void, Never>?

        private static let environment = ProcessInfo.processInfo.environment

        private static var sampleCount: Int {
            max(10, Int(environment["CMUX_LATENCY_SAMPLES"] ?? "") ?? 120)
        }

        private static var cadenceSeconds: Double {
            max(2, Double(environment["CMUX_LATENCY_CADENCE_SECONDS"] ?? "") ?? 8)
        }

        private static var reportPath: String {
            environment["CMUX_LATENCY_REPORT_PATH"] ?? "/tmp/cmux-ios-latency.json"
        }

        private static var runLabel: String {
            environment["CMUX_LATENCY_PROBE_LABEL"] ?? "unlabeled"
        }

        func start() {
            probeTask = Task { await run() }
        }

        func stop() {
            probeTask?.cancel()
            probeTask = nil
            tearDownCadenceLink()
        }

        // MARK: - Probe phases

        private func run() async {
            guard let view = surfaceView else { return }
            probeLog.info("latencyProbe: starting label=\(Self.runLabel, privacy: .public) samples=\(Self.sampleCount, privacy: .public)")

            await waitForWindowAttach(view)
            await warmUp(view)
            guard !Task.isCancelled else { return }

            var processedMs: [Double] = []
            var renderedMs: [Double] = []
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            for index in 0..<Self.sampleCount {
                guard !Task.isCancelled else { return }
                let char = String(alphabet[index % alphabet.count])
                let sample = await measureKeystroke(view, text: char)
                processedMs.append(sample.processedMs)
                renderedMs.append(sample.renderedMs)
                // Keep lines bounded so the probe's grid state stays simple.
                if index % 48 == 47 {
                    view.processOutput(Data("\r\n".utf8))
                }
            }

            // Verify the byte stream really landed in the terminal grid, not
            // just that the completion callbacks fired: echo a unique marker
            // and look for it in the surface's readable text.
            let marker = "LATENCYPROBE-END"
            _ = await measureKeystroke(view, text: marker)
            let verified = (await view.renderedSurfaceTextForTesting())?.contains(marker) ?? false

            guard !Task.isCancelled else { return }
            let intervals = await runCadencePhase(view, seconds: Self.cadenceSeconds)

            let report = MobileTerminalLatencyReport(
                capturedAtEpoch: Date().timeIntervalSince1970,
                label: Self.runLabel,
                typingProcessed: .init(samplesMs: processedMs),
                typingRendered: .init(samplesMs: renderedMs),
                cadenceFrameIntervals: .init(samplesMs: intervals),
                cadenceHitchesOver33Ms: intervals.count(where: { $0 > 33 }),
                cadenceHitchesOver100Ms: intervals.count(where: { $0 > 100 }),
                surfaceTextVerified: verified
            )
            writeReport(report)
        }

        /// Waits until the surface view is attached to a window (the display
        /// link — and therefore rendering — only runs while attached).
        /// Probe-only polling sleep: this is test scaffolding, exempt from the
        /// no-sleep rule, and there is no attach signal to await instead.
        private func waitForWindowAttach(_ view: GhosttySurfaceView) async {
            while !Task.isCancelled, view.window == nil {
                try? await ContinuousClock().sleep(for: .milliseconds(50))
            }
        }

        /// Feeds a banner through the full output path a few times so config,
        /// font atlas, and first-frame costs do not pollute the samples.
        private func warmUp(_ view: GhosttySurfaceView) async {
            for index in 0..<10 {
                guard !Task.isCancelled else { return }
                _ = await measureOutputRoundTrip(
                    view,
                    data: Data("warmup \(index) \u{1b}[32mready\u{1b}[0m\r\n".utf8)
                )
            }
        }

        /// One keystroke through the REAL input path: the soft-keyboard text
        /// change on `TerminalInputTextView` commits the text, the delegate
        /// (self) echoes the produced bytes back into `processOutput`, and the
        /// two DEBUG seams time bytes-applied and render-complete.
        ///
        /// No per-keystroke timeout on purpose: if the byte/render pipeline
        /// wedges (the 0x8BADF00D failure class this probe exists to catch),
        /// the run hangs, no report file appears, and the driver script's
        /// timeout reports the failure.
        private func measureKeystroke(_ view: GhosttySurfaceView, text: String) async -> (processedMs: Double, renderedMs: Double) {
            await withCheckedContinuation { continuation in
                let start = CACurrentMediaTime()
                var processedAt: CFTimeInterval?
                var renderedAt: CFTimeInterval?
                let finishIfDone = { [weak view] in
                    guard let processedAt, let renderedAt else { return }
                    view?.onOutputProcessedForTesting = nil
                    view?.onRenderCompletedForTesting = nil
                    continuation.resume(returning: (
                        processedMs: (processedAt - start) * 1000,
                        renderedMs: (renderedAt - start) * 1000
                    ))
                }
                view.onOutputProcessedForTesting = {
                    if processedAt == nil { processedAt = CACurrentMediaTime() }
                    finishIfDone()
                }
                view.onRenderCompletedForTesting = {
                    // Only count a render that happened after the bytes landed.
                    guard processedAt != nil else { return }
                    if renderedAt == nil { renderedAt = CACurrentMediaTime() }
                    finishIfDone()
                }
                view.simulateInputProxyTextChangeForTesting(text, isComposing: false)
            }
        }

        /// One raw output chunk through `processOutput`, awaited to applied.
        private func measureOutputRoundTrip(_ view: GhosttySurfaceView, data: Data) async -> Double {
            await withCheckedContinuation { continuation in
                let start = CACurrentMediaTime()
                view.onOutputProcessedForTesting = { [weak view] in
                    view?.onOutputProcessedForTesting = nil
                    continuation.resume(returning: (CACurrentMediaTime() - start) * 1000)
                }
                view.processOutput(data)
            }
        }

        /// Streams one output line per display-link frame for `seconds`,
        /// recording the probe's own main-thread frame intervals. Hitches here
        /// mean the main thread (or the byte path back-pressuring it) stalled.
        private func runCadencePhase(_ view: GhosttySurfaceView, seconds: Double) async -> [Double] {
            cadenceTimestamps = []
            cadenceLineNumber = 0
            cadenceDeadlineSeconds = seconds
            let link = CADisplayLink(
                target: LatencyProbeDisplayLinkProxy(target: self),
                selector: #selector(LatencyProbeDisplayLinkProxy.handleDisplayLink)
            )
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            cadenceLink = link
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cadenceCompletion = continuation
            }
            tearDownCadenceLink()
            var intervals: [Double] = []
            intervals.reserveCapacity(max(0, cadenceTimestamps.count - 1))
            for index in 1..<max(1, cadenceTimestamps.count) {
                intervals.append((cadenceTimestamps[index] - cadenceTimestamps[index - 1]) * 1000)
            }
            return intervals
        }

        fileprivate func handleCadenceTick(_ link: CADisplayLink) {
            cadenceTimestamps.append(link.timestamp)
            cadenceLineNumber += 1
            surfaceView?.processOutput(
                Data("cadence \(cadenceLineNumber) \u{1b}[32mgreen\u{1b}[0m streaming row to exercise the byte path\r\n".utf8)
            )
            if let first = cadenceTimestamps.first,
               link.timestamp - first >= cadenceDeadlineSeconds {
                cadenceCompletion?.resume()
                cadenceCompletion = nil
                link.isPaused = true
            }
        }

        private func tearDownCadenceLink() {
            cadenceLink?.invalidate()
            cadenceLink = nil
        }

        // MARK: - Reporting

        private func writeReport(_ report: MobileTerminalLatencyReport) {
            let path = Self.reportPath
            do {
                let data = try report.jsonData()
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                probeLog.info("latencyProbe: report written to \(path, privacy: .public)")
                MobileDebugLog.anchormux("latencyProbe.done report=\(path)")
            } catch {
                probeLog.error("latencyProbe: failed to write report: \(String(describing: error), privacy: .public)")
            }
        }

        // MARK: - GhosttySurfaceViewDelegate (local echo)

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            // Zero-delay local echo: stand in for the Mac's PTY echo so the
            // measured latency is purely the on-device pipeline.
            surfaceView.processOutput(data)
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
            // No effective-grid pin: the probe renders at its natural grid.
        }
    }
}

/// Weak-target trampoline so the cadence `CADisplayLink` (which retains its
/// target) cannot keep the coordinator alive past dismantle.
@MainActor
private final class LatencyProbeDisplayLinkProxy {
    private weak var target: LatencyProbeRepresentable.Coordinator?

    init(target: LatencyProbeRepresentable.Coordinator) {
        self.target = target
    }

    @objc func handleDisplayLink(_ link: CADisplayLink) {
        target?.handleCadenceTick(link)
    }
}
#endif
