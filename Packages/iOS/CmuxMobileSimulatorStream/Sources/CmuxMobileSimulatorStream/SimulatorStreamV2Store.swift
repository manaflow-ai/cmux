import CmuxMobileRPC
import CmuxSimulatorStreamKit
import Foundation
import Observation

/// Viewer-facing phase for one panel's stream, derived from the lifecycle
/// machine plus the last host state.
public enum SimStreamViewerPhase: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case reconnecting
    case unavailable(detail: String)
    case stopped
}

/// Main-actor owner of one panel's simulator stream v2 session.
///
/// All policy lives in `SimStreamViewerLifecycle` (pure, tested); this store
/// executes its actions: it spawns one `SimStreamViewerEngine` per attach,
/// tears it down on the machine's say-so, and re-attaches through exactly one
/// path. There are no keepalives and only one watchdog: "no frame presented
/// while streaming for too long means rebuild".
@MainActor
@Observable
public final class SimulatorStreamV2Store {
    public private(set) var phase: SimStreamViewerPhase = .idle
    public private(set) var hostDetail: String = ""
    public private(set) var lastPresentedFrameAt: Date?
    /// Bumps on every presented frame; cheap SwiftUI invalidation hook.
    public private(set) var presentedFrameCount: UInt64 = 0

    public let panelID: String

    @ObservationIgnored private var lifecycle = SimStreamViewerLifecycle()
    @ObservationIgnored private var engine: SimStreamViewerEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var presenter: (any SimStreamFramePresenting)?
    @ObservationIgnored private let opener: SimStreamViewerEngine.LaneOpener
    @ObservationIgnored private let transportReady: @MainActor () -> Bool
    @ObservationIgnored private let maximumLongSidePixels: UInt16
    @ObservationIgnored private let clock: any Clock<Duration>
    /// Streaming with no presented frame for this long means the pipeline is
    /// wedged somewhere invisible; rebuild it.
    @ObservationIgnored private let progressTimeout: Duration

    public init(
        panelID: String,
        opener: @escaping SimStreamViewerEngine.LaneOpener,
        transportReady: @escaping @MainActor () -> Bool,
        maximumLongSidePixels: UInt16 = 2_000,
        clock: any Clock<Duration> = ContinuousClock(),
        progressTimeout: Duration = .seconds(8)
    ) {
        self.panelID = panelID
        self.opener = opener
        self.transportReady = transportReady
        self.maximumLongSidePixels = maximumLongSidePixels
        self.clock = clock
        self.progressTimeout = progressTimeout
    }

    // MARK: - External lifecycle

    public func bindPresenter(_ presenter: any SimStreamFramePresenting) {
        self.presenter = presenter
    }

    public func activate() {
        apply(lifecycle.handle(.activate))
        if transportReady() {
            apply(lifecycle.handle(.transportReady))
        }
        refreshPhase()
    }

    public func deactivate() {
        apply(lifecycle.handle(.deactivate))
        refreshPhase()
    }

    public func noteTransportReady(_ ready: Bool) {
        apply(lifecycle.handle(ready ? .transportReady : .transportLost))
        refreshPhase()
    }

    public func appBackgrounded() {
        apply(lifecycle.handle(.appBackgrounded))
        refreshPhase()
    }

    public func appForegrounded() {
        apply(lifecycle.handle(.appForegrounded))
        if transportReady() {
            apply(lifecycle.handle(.transportReady))
        }
        refreshPhase()
    }

    // MARK: - Input forwarding

    public func send(_ event: SimStreamInputEvent) {
        guard let engine else { return }
        Task { await engine.send(event) }
    }

    public func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send(.text(text))
    }

    public func sendButton(_ button: SimStreamHardwareButton) {
        send(.button(button))
    }

    // MARK: - Machine execution

    private func apply(_ action: SimStreamViewerLifecycle.Action) {
        switch action {
        case .none:
            break
        case .openLaneAndStart:
            openLaneAndStart()
        case .teardown:
            teardown()
        case .teardownAndRetry(let delay):
            teardown()
            scheduleRetry(after: delay)
        }
    }

    private func openLaneAndStart() {
        guard let presenter else {
            // The view has not mounted yet; treat as a wedge so the machine
            // retries shortly instead of silently dying.
            apply(lifecycle.handle(.streamWedged(reason: "presenter unbound")))
            refreshPhase()
            return
        }
        epoch += 1
        let engine = SimStreamViewerEngine(
            presenter: presenter,
            maximumLongSidePixels: maximumLongSidePixels,
            epoch: epoch,
            onEvent: { [weak self] event in
                Task { @MainActor in
                    self?.handleEngineEvent(event)
                }
            }
        )
        self.engine = engine
        let opener = opener
        runTask = Task {
            await engine.run(opener: opener)
        }
        startProgressWatchdog()
    }

    private func teardown() {
        runTask?.cancel()
        runTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        retryTask?.cancel()
        retryTask = nil
        let engine = engine
        self.engine = nil
        let presenter = presenter
        Task {
            await engine?.stop()
            await presenter?.reset()
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        let clock = clock
        retryTask = Task { [weak self] in
            try? await clock.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.apply(self.lifecycle.handle(.retryDelayElapsed))
                if self.transportReady() {
                    self.apply(self.lifecycle.handle(.transportReady))
                }
                self.refreshPhase()
            }
        }
    }

    private func startProgressWatchdog() {
        watchdogTask?.cancel()
        let clock = clock
        let timeout = progressTimeout
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                let wedged = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    guard self.lifecycle.phase == .streaming
                        || self.lifecycle.phase == .starting
                    else { return false }
                    if let last = self.lastPresentedFrameAt,
                        Date().timeIntervalSince(last)
                            < Double(timeout.components.seconds)
                    {
                        return false
                    }
                    return true
                }
                guard wedged else { continue }
                await MainActor.run {
                    guard let self else { return }
                    self.apply(
                        self.lifecycle.handle(.streamWedged(reason: "no frame progress")))
                    self.refreshPhase()
                }
                return
            }
        }
    }

    // MARK: - Engine events

    private func handleEngineEvent(_ event: SimStreamViewerEvent) {
        switch event {
        case .configured:
            apply(lifecycle.handle(.startSucceeded))
        case .framePresented:
            lastPresentedFrameAt = Date()
            presentedFrameCount &+= 1
            apply(lifecycle.handle(.framePresented))
        case .hostState(let update):
            hostDetail = update.detail
            switch update.status {
            case .closed:
                apply(lifecycle.handle(.hostEnded(status: .closed, detail: update.detail)))
            case .preparing, .streaming, .deviceUnavailable, .workerCrashed, .failed:
                // Informational: the host self-heals worker crashes and
                // device churn behind the same stream; the next keyframe
                // repaints. Only `closed` is terminal.
                break
            }
        case .ended(let clean):
            apply(
                lifecycle.handle(
                    .streamWedged(reason: clean ? "host finished" : "lane failed")))
        }
        refreshPhase()
    }

    private func refreshPhase() {
        switch lifecycle.phase {
        case .idle:
            phase = .idle
        case .waitingForTransport, .starting:
            phase = presentedFrameCount > 0 ? .reconnecting : .connecting
        case .streaming:
            phase = .streaming
        case .retrying:
            phase = .reconnecting
        case .backgrounded, .stopped:
            phase = .stopped
        case .unavailable(let reason):
            phase = .unavailable(detail: reason)
        }
    }
}
