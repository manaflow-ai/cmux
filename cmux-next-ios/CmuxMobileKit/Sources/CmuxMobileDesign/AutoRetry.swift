import Foundation
import Observation
#if os(iOS)
import SwiftUI
#endif

/// Jittered exponential backoff for ``AutoRetry``: retry `n` (0-based) waits
/// `min(cap, first * 2^n)`, drawn uniformly from its upper half so phones that
/// failed together do not retry together.
public struct AutoRetryBackoff: Sendable, Equatable {
    public var first: Duration
    public var cap: Duration

    public init(first: Duration, cap: Duration) {
        self.first = first
        self.cap = cap
    }

    /// 1 s, 2 s, 4 s ... up to 30 s between attempts.
    public static let standard = AutoRetryBackoff(first: .seconds(1), cap: .seconds(30))

    /// The wait before retry `n`; `unit` is a random draw in 0...1.
    public func delay(beforeRetry n: Int, unit: Double) -> Duration {
        let full = min(cap, first * (1 << min(max(n, 0), 20)))
        let draw = min(max(unit, 0), 1)
        return full * (0.5 + 0.5 * draw)
    }
}

/// Retries a failed load on its own, so a screen never asks "Try Again" for a
/// fetch, a reconnect or a list reload whose only answer is yes.
///
/// Leo, 2026-11-22: "vacuous decisions like that should be just done and the
/// underlying problems should be done better at the root".
///
/// - While the screen is visible and the app is in the foreground, a failure is
///   retried with ``AutoRetryBackoff`` (1 s, 2 s, 4 s ... 30 s, jittered).
/// - Coming back to the foreground (or the screen appearing again) retries once
///   at once.
/// - Nothing shows at first. Once the failure has lasted ``QuietStatusGate/threshold``
///   (the shared quiet bound), ``isQuietLineShown`` turns on for one quiet line; it
///   never offers a button.
///
/// `perform` must return when its attempt has answered (succeeded or failed):
/// the failure in between (a "loading" phase) does not count as recovered.
@MainActor
@Observable
public final class AutoRetry {
    /// The failure has lasted past the quiet bound: show one quiet line, no button.
    public var isQuietLineShown: Bool { gate.isShown }
    /// Attempts made since the last success (tests and diagnostics).
    public private(set) var attempts = 0

    @ObservationIgnored private let gate: QuietStatusGate
    @ObservationIgnored private let backoff: AutoRetryBackoff
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let draw: () -> Double
    @ObservationIgnored private var perform: (@MainActor () async -> Void)?
    @ObservationIgnored private var failing = false
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var attemptTask: Task<Void, Never>?
    @ObservationIgnored private var attemptGeneration = 0

    public init(backoff: AutoRetryBackoff = .standard,
                quiet: Duration = QuietStatusGate.threshold,
                clock: any Clock<Duration> = ContinuousClock(),
                draw: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.backoff = backoff
        self.gate = QuietStatusGate(delay: quiet, clock: clock)
        self.clock = clock
        self.draw = draw
    }

    /// The attempt to run on each retry (the latest one wins).
    public func setAttempt(_ perform: @escaping @MainActor () async -> Void) {
        self.perform = perform
    }

    /// The screen's load failed (true) or is fine or loading (false).
    public func update(failing: Bool) {
        self.failing = failing
        if failing {
            gate.update(down: true)
            schedule(immediately: false)
        } else if !inFlight {
            recovered()
        }
    }

    /// The app is in the foreground (`scenePhase == .active`) or not.
    public func update(foreground: Bool) {
        let returned = foreground && !self.foreground
        self.foreground = foreground
        if !foreground { stopLoop(cancelAttempt: true) } else if returned { schedule(immediately: true) }
    }

    /// The screen is on screen or not.
    public func update(visible: Bool) {
        let returned = visible && !self.visible
        self.visible = visible
        if !visible { stopLoop(cancelAttempt: true) } else if returned { schedule(immediately: true) }
    }

    /// An attempt is running now (a return to the screen meanwhile starts none of its own).
    public var isAttemptInFlight: Bool { inFlight }

    private var canRun: Bool { failing && visible && foreground && !inFlight }

    private func schedule(immediately: Bool) {
        guard canRun, immediately || loop == nil else { return }
        loop?.cancel()
        let delay: Duration = immediately ? .zero : backoff.delay(beforeRetry: attempts, unit: draw())
        let clock = clock
        // An intentional, bounded backoff on the injected clock; leaving the screen or the
        // foreground cancels it.
        loop = Task { [weak self] in
            if delay > .zero {
                do { try await clock.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled, self.canRun else { return }
            await self.runAttempt()
        }
    }

    private func runAttempt() async {
        guard let perform else { return }
        inFlight = true
        attempts += 1
        attemptGeneration += 1
        let generation = attemptGeneration
        // Keep a handle so leaving the screen or backgrounding can cancel the read. The
        // generation guard below ignores a late answer from a non-cooperative backend.
        let task = Task { @MainActor in await perform() }
        attemptTask = task
        await task.value
        guard generation == attemptGeneration else { return }
        inFlight = false
        attemptTask = nil
        loop = nil
        if failing { schedule(immediately: false) } else { recovered() }
    }

    private func stopLoop(cancelAttempt: Bool = false) {
        loop?.cancel()
        loop = nil
        guard cancelAttempt else { return }
        attemptGeneration += 1
        attemptTask?.cancel()
        attemptTask = nil
        inFlight = false
    }

    private func recovered() {
        stopLoop()
        attempts = 0
        gate.update(down: false)
    }
}

#if os(iOS)
private struct AutoRetryModifier: ViewModifier {
    let retry: AutoRetry
    let failing: Bool
    let perform: @MainActor () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                retry.setAttempt(perform)
                retry.update(visible: true)
            }
            .onDisappear { retry.update(visible: false) }
            .onChange(of: failing, initial: true) { _, now in
                retry.setAttempt(perform)
                retry.update(failing: now)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                retry.update(foreground: phase == .active)
            }
    }
}

public extension View {
    /// Retries `perform` on its own while `failing` (see ``AutoRetry``). Show
    /// ``AutoRetryQuietLine`` (or read ``AutoRetry/isQuietLineShown``) where the
    /// screen says so after the quiet bound; never a Try Again button.
    func autoRetry(_ retry: AutoRetry, failing: Bool, perform: @escaping @MainActor () async -> Void) -> some View {
        modifier(AutoRetryModifier(retry: retry, failing: failing, perform: perform))
    }
}

/// The one quiet line a failing ``AutoRetry`` shows past the quiet bound: no
/// button, nothing before the bound.
public struct AutoRetryQuietLine: View {
    let retry: AutoRetry
    let text: Text

    public init(_ retry: AutoRetry, _ text: Text) {
        self.retry = retry
        self.text = text
    }

    /// The default line.
    public static var defaultText: String {
        String(localized: "recovery.autoRetry", defaultValue: "Still trying…", bundle: .module)
    }

    public init(_ retry: AutoRetry) {
        self.init(retry, Text(verbatim: Self.defaultText))
    }

    public var body: some View {
        if retry.isQuietLineShown {
            text
                .font(CmuxMobileTheme.standard.type.meta)
                .foregroundStyle(CmuxMobileTheme.standard.colors.label2.color)
                .multilineTextAlignment(.center)
                .transition(.opacity)
                .accessibilityIdentifier("autoRetry.quietLine")
        }
    }
}
#endif
