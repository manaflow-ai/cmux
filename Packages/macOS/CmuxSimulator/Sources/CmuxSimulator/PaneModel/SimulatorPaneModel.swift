public import Foundation
internal import Observation

/// The observable state behind one simulator pane.
///
/// Owns the whole pipeline for one pane: resolve the device query against the
/// catalog, open a ``SimulatorDeviceSession`` (boot or attach per policy),
/// then consume the capture backend's frame stream and project the latest
/// frame for SwiftUI. Teardown reverses it: cancel the stream, then close the
/// session (which shuts the device down only when cmux booted it).
///
/// Construct with fakes for tests:
///
/// ```swift
/// let model = SimulatorPaneModel(
///     deviceQuery: "iPhone 17 Pro",
///     runner: fakeRunner,                 // any SimctlCommandRunning
///     captureBackend: fakeCapture         // any SimulatorDisplayCapturing
/// )
/// model.start()
/// ```
@MainActor
@Observable
public final class SimulatorPaneModel {
    /// The pane's current lifecycle phase.
    public private(set) var phase: SimulatorPanePhase = .idle
    /// The most recent display frame, if any arrived yet.
    public private(set) var latestFrame: SimulatorDisplayFrame?
    /// The resolved device record, once the query resolved.
    public private(set) var device: SimulatorDevice?
    /// Who owns the device's shutdown, once the session opened.
    public private(set) var ownership: SimulatorSessionOwnership?
    /// The `--device` query this pane was opened with (a name or UDID).
    public let deviceQuery: String

    private let runner: any SimctlCommandRunning
    private let captureBackend: any SimulatorDisplayCapturing
    private let policy: SimulatorLifecyclePolicy
    private var session: SimulatorDeviceSession?
    private var runTask: Task<Void, Never>?

    /// Creates a pane model.
    ///
    /// - Parameters:
    ///   - deviceQuery: The device to display, as a name or UDID.
    ///   - runner: The `simctl` seam. Defaults to the real subprocess runner.
    ///   - captureBackend: The display capture seam. Defaults to the
    ///     `simctl` screenshot-streaming backend over `runner`.
    ///   - policy: The lifecycle decision rules.
    public init(
        deviceQuery: String,
        runner: (any SimctlCommandRunning)? = nil,
        captureBackend: (any SimulatorDisplayCapturing)? = nil,
        policy: SimulatorLifecyclePolicy = SimulatorLifecyclePolicy()
    ) {
        let resolvedRunner = runner ?? SimctlCommandRunner()
        self.deviceQuery = deviceQuery
        self.runner = resolvedRunner
        self.captureBackend = captureBackend ?? SimctlScreenshotCaptureBackend(runner: resolvedRunner)
        self.policy = policy
    }

    /// Starts the session pipeline. Safe to call more than once; only the
    /// first call while stopped does anything.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    /// Tears the pane down: stops streaming and closes the session, which
    /// shuts the device down only when this pane's session booted it.
    public func closePane() {
        runTask?.cancel()
        runTask = nil
        let session = session
        self.session = nil
        if phase != .idle, !isFailed {
            phase = .stopped
        }
        guard let session else { return }
        // Fire-and-forget: pane teardown must not block the UI on simctl.
        Task.detached {
            try? await session.close()
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func run() async {
        phase = .resolvingDevice
        do {
            let listOutput = try await runner.run(["list", "devices", "--json"])
            let catalog = try SimulatorDeviceCatalog(simctlListJSON: listOutput)
            guard let device = catalog.device(matching: deviceQuery) else {
                phase = .failed(.deviceNotFound(query: deviceQuery))
                return
            }
            self.device = device
            let session = SimulatorDeviceSession(udid: device.udid, runner: runner, policy: policy)
            self.session = session
            phase = device.state == .booted ? .attaching : .booting
            ownership = try await session.open()
            guard !Task.isCancelled else { return }
            phase = .streaming
            for await frame in captureBackend.frames(for: device.udid) {
                latestFrame = frame
            }
            if phase == .streaming {
                phase = .stopped
            }
        } catch is CancellationError {
            // closePane() already set the terminal phase.
        } catch {
            phase = .failed(.sessionFailed(detail: String(describing: error)))
        }
    }
}
