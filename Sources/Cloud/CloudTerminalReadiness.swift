import CmuxTerminal
import Foundation
import Observation
import os

private let cloudTerminalReadinessLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "CloudTerminalPresentation"
)

/// Event-driven readiness for a Cloud terminal handoff.
///
/// Readiness is established by the first presented frame that satisfies the
/// caller's lifecycle condition. No timer or frame polling is used, and the
/// local render-demand lease is released as soon as the frame arrives.
@MainActor
@Observable
final class CloudTerminalReadiness {
    typealias Phase = CloudTerminalReadinessPhase

    private(set) var phase: Phase = .idle
    var isLoading: Bool { phase == .waiting }

    private weak var surface: TerminalSurface?
    private var gate = CloudTerminalReadinessGate()
    private var condition: (@MainActor () -> Bool)?
    private var onReady: (@MainActor () -> Void)?
    private var onEnded: (@MainActor () -> Void)?
    private var onTimedOut: (@MainActor () -> Void)?
    // The task is created and cancelled on MainActor; ARC deinit is nonisolated.
    private nonisolated(unsafe) var deadlineTask: Task<Void, Never>?
    private let clock: any Clock<Duration>
    private let deadline: Duration
    // Notification tokens are only touched on the main actor; the unsafe
    // annotation permits the nonisolated ARC deinit to release them safely.
    private nonisolated(unsafe) var frameObserver: NSObjectProtocol?
    private nonisolated(unsafe) var runtimeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var releaseFrameDemand: (() -> Void)?

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        deadline: Duration = .seconds(60)
    ) {
        self.clock = clock
        self.deadline = deadline
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        deadlineTask?.cancel()
        releaseFrameDemand?()
    }

    /// Begins a readiness transaction for one native terminal surface.
    func begin(
        surface: TerminalSurface,
        condition: @escaping @MainActor () -> Bool,
        onReady: @escaping @MainActor () -> Void,
        onEnded: (@MainActor () -> Void)? = nil,
        onTimedOut: (@MainActor () -> Void)? = nil
    ) {
        let previousOnReady = phase == .waiting ? self.onReady : nil
        let previousOnEnded = phase == .waiting ? self.onEnded : nil
        let previousOnTimedOut = phase == .waiting ? self.onTimedOut : nil
        let previousCondition = phase == .waiting ? self.condition : nil
        finishEnd(notify: false)
        self.surface = surface
        gate.begin(baselineFrame: surface.hostedView.surfaceView.renderedFrameSequence)
        self.condition = previousCondition.map { previous in
            { previous() && condition() }
        } ?? condition
        self.onReady = Self.composed(previousOnReady, onReady)
        self.onEnded = Self.composed(previousOnEnded, onEnded)
        self.onTimedOut = Self.composed(previousOnTimedOut, onTimedOut)
        phase = .waiting
        cloudTerminalReadinessLogger.info(
            "readiness surface=\(surface.id.uuidString, privacy: .private(mask: .hash)) phase=waiting baseline=\(self.gate.baselineFrame)"
        )
        let view = surface.hostedView.surfaceView
        releaseFrameDemand = view.retainLocalRenderedFrameNotifications()
        installObservers(surface: surface, view: view)
        armDeadline()
        check()
    }

    func resumeDeadline() {
        guard phase == .waiting, deadlineTask == nil else { return }
        armDeadline()
    }

    private func armDeadline() {
        deadlineTask = Task { @MainActor [weak self, clock = self.clock, deadline = self.deadline] in
            do { try await clock.sleep(for: deadline) } catch { return }
            guard let self, self.phase == .waiting else { return }
            if self.surface?.isRendererEffectivelyVisible == false {
                self.deadlineTask = nil
                return
            }
            self.onTimedOut?()
            self.end()
        }
    }

    /// Rearms the same surface after a reconnect without creating another
    /// observer or retaining a second render-demand lease.
    func rearm() {
        guard let surface else { return }
        gate.begin(baselineFrame: surface.hostedView.surfaceView.renderedFrameSequence)
        phase = .waiting
        if frameObserver == nil {
            releaseFrameDemand = surface.hostedView.surfaceView.retainLocalRenderedFrameNotifications()
            installObservers(surface: surface, view: surface.hostedView.surfaceView)
        }
        deadlineTask?.cancel()
        armDeadline()
        check()
    }

    /// Checks the current lifecycle and rendered-frame generation.
    func check() {
        guard phase == .waiting,
              let surface,
              surface.hasLiveSurface else {
            return
        }
        let frame = surface.hostedView.surfaceView.renderedFrameSequence
        guard gate.check(
            attachmentReady: condition?() == true,
            rendererPresented: surface.isRendererPresented && surface.isRendererEffectivelyVisible,
            frameSequence: frame
        ) else { return }
        phase = .ready
        deadlineTask?.cancel()
        deadlineTask = nil
        cloudTerminalReadinessLogger.info(
            "readiness surface=\(surface.id.uuidString, privacy: .private(mask: .hash)) phase=ready frame=\(frame)"
        )
        let callback = onReady
        releaseObservers()
        callback?()
    }

    /// Ends readiness permanently and releases observation resources.
    func end() {
        finishEnd(notify: true)
    }

    private func finishEnd(notify: Bool) {
        let shouldNotify = notify && phase != .ended
        deadlineTask?.cancel()
        deadlineTask = nil
        releaseObservers()
        if phase != .ended { phase = .ended }
        if shouldNotify { onEnded?() }
    }

    private func installObservers(surface: TerminalSurface, view: GhosttyNSView) {
        guard frameObserver == nil, runtimeObserver == nil else { return }
        frameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame, object: view, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady, object: surface, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    }

    private func releaseObservers() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        frameObserver = nil
        runtimeObserver = nil
        releaseFrameDemand?()
        releaseFrameDemand = nil
    }

    private static func composed(
        _ first: (@MainActor () -> Void)?,
        _ second: (@MainActor () -> Void)?
    ) -> (@MainActor () -> Void)? {
        switch (first, second) {
        case let (.some(first), .some(second)):
            return { first(); second() }
        case (.some, .none): return first
        case (.none, .some): return second
        case (.none, .none): return nil
        }
    }
}
