import CmuxTerminal
import Foundation
import Observation
import os

private let cloudTerminalReadinessLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "CloudTerminalPresentation"
)

/// Pure ordering fence for one terminal presentation generation.
///
/// Replay and rendering can arrive in either order around reconnects. The gate
/// only opens when attachment state is true, replay has been applied through the
/// caller's condition, and a frame newer than the generation baseline has been
/// presented. It is small enough to exercise without constructing Ghostty.
struct CloudTerminalReadinessGate: Equatable, Sendable {
    private(set) var baselineFrame: UInt64 = 0
    private(set) var firstPresentedFrame: UInt64? = nil

    mutating func begin(baselineFrame: UInt64) {
        self.baselineFrame = baselineFrame
        firstPresentedFrame = nil
    }

    mutating func check(
        attachmentReady: Bool,
        rendererPresented: Bool,
        frameSequence: UInt64
    ) -> Bool {
        guard firstPresentedFrame == nil,
              attachmentReady,
              rendererPresented,
              frameSequence > baselineFrame else { return false }
        firstPresentedFrame = frameSequence
        return true
    }
}

/// Event-driven readiness for a Cloud terminal handoff.
///
/// Readiness is established by the first presented frame that satisfies the
/// caller's lifecycle condition. No timer or frame polling is used, and the
/// local render-demand lease is released as soon as the frame arrives.
@MainActor
@Observable
final class CloudTerminalReadiness {
    enum Phase: Equatable, Sendable {
        case idle
        case waiting
        case ready
        case ended
    }

    private(set) var phase: Phase = .idle
    var isLoading: Bool { phase == .waiting }

    private weak var surface: TerminalSurface?
    private var gate = CloudTerminalReadinessGate()
    private var condition: (@MainActor () -> Bool)?
    private var onReady: (@MainActor () -> Void)?
    private var onEnded: (@MainActor () -> Void)?
    // Notification tokens are only touched on the main actor; the unsafe
    // annotation permits the nonisolated ARC deinit to release them safely.
    private nonisolated(unsafe) var frameObserver: NSObjectProtocol?
    private nonisolated(unsafe) var runtimeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var releaseFrameDemand: (() -> Void)?

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        releaseFrameDemand?()
    }

    /// Begins a readiness transaction for one native terminal surface.
    func begin(
        surface: TerminalSurface,
        condition: @escaping @MainActor () -> Bool,
        onReady: @escaping @MainActor () -> Void,
        onEnded: (@MainActor () -> Void)? = nil
    ) {
        let previousOnReady = phase == .waiting ? self.onReady : nil
        let previousOnEnded = phase == .waiting ? self.onEnded : nil
        finishEnd(notify: false)
        self.surface = surface
        gate.begin(baselineFrame: surface.hostedView.surfaceView.renderedFrameSequence)
        self.condition = condition
        self.onReady = Self.composed(previousOnReady, onReady)
        self.onEnded = Self.composed(previousOnEnded, onEnded)
        phase = .waiting
        cloudTerminalReadinessLogger.info(
            "readiness surface=\(surface.id.uuidString, privacy: .private(mask: .hash)) phase=waiting baseline=\(self.gate.baselineFrame)"
        )
        let view = surface.hostedView.surfaceView
        releaseFrameDemand = view.retainLocalRenderedFrameNotifications()
        frameObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: view,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: surface,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    /// Rearms the same surface after a reconnect without creating another
    /// observer or retaining a second render-demand lease.
    func rearm() {
        guard let surface else { return }
        gate.begin(baselineFrame: surface.hostedView.surfaceView.renderedFrameSequence)
        phase = .waiting
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
        releaseObservers()
        if phase != .ended { phase = .ended }
        if shouldNotify { onEnded?() }
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
