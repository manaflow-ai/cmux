#if os(iOS)
import Foundation
import Observation

/// Drives deterministic playback of a ``WelcomeDemoScript``.
///
/// The engine reveals transcript lines on a cadence from an injected clock,
/// pauses on the script's question until ``choose(_:)``, then plays the chosen
/// resolution. Tests advance a test clock to step playback; the preview and
/// Reduce Motion paths pass `revealsInstantly: true` to collapse every delay.
///
/// ```swift
/// let engine = WelcomeDemoEngine()
/// engine.start()
/// // …transcript reveals, then engine.phase == .awaitingReply
/// engine.choose(engine.question!.replies[0])
/// ```
@MainActor
@Observable
final class WelcomeDemoEngine {
    /// Where playback currently stands.
    enum Phase: Equatable {
        /// `start()` has not run yet.
        case idle
        /// Lines are revealing on the clock cadence.
        case playing
        /// The agent's question is on screen and replies are tappable.
        case awaitingReply
        /// The chosen resolution finished; the transcript is complete.
        case finished
    }

    /// The revealed transcript, oldest first.
    private(set) var lines: [WelcomeDemoLine] = []
    /// The current playback phase.
    private(set) var phase: Phase = .idle
    /// The pending question while ``phase`` is ``Phase/awaitingReply``.
    private(set) var question: WelcomeDemoQuestion?

    private let script: WelcomeDemoScript
    private let clock: any Clock<Duration>
    private let revealsInstantly: Bool
    /// The cadence between revealed lines; visible-but-brisk by default.
    private let lineDelay: Duration
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    /// Creates an engine for one playthrough of `script`.
    ///
    /// - Parameters:
    ///   - script: The steps to play. Defaults to the standard first-run script.
    ///   - clock: The cadence source. Tests inject a test clock; the default
    ///     is the continuous wall clock.
    ///   - revealsInstantly: When `true`, every delay collapses to nothing so
    ///     the transcript reaches the question in one turn (Reduce Motion and
    ///     the deterministic UI-test preview).
    ///   - lineDelay: The pause before each revealed line.
    init(
        script: WelcomeDemoScript = WelcomeDemoScript(),
        clock: any Clock<Duration> = ContinuousClock(),
        revealsInstantly: Bool = false,
        lineDelay: Duration = .milliseconds(650)
    ) {
        self.script = script
        self.clock = clock
        self.revealsInstantly = revealsInstantly
        self.lineDelay = lineDelay
    }

    /// Begins playback once; later calls while playback is underway are ignored.
    func start() {
        guard phase == .idle else { return }
        phase = .playing
        play(steps: script.steps, thenFinish: false)
    }

    /// Echoes the chosen reply and plays its resolution to completion.
    /// - Parameter reply: One of the pending question's replies.
    func choose(_ reply: WelcomeDemoReply) {
        guard phase == .awaitingReply, let question else { return }
        self.question = nil
        phase = .playing
        lines.append(WelcomeDemoLine(
            id: question.prompt.id + 100 + reply.id,
            style: .reply,
            text: reply.echo
        ))
        play(steps: reply.resolution.map { .line($0) }, thenFinish: true)
    }

    /// Cancels in-flight playback; called when the stage leaves the screen.
    func cancel() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    /// Runs `steps` synchronously in instant mode (deterministic for tests and
    /// the UI-test preview) or on the clock cadence otherwise.
    private func play(steps: [WelcomeDemoStep], thenFinish: Bool) {
        if revealsInstantly {
            for step in steps {
                if applied(step) == .paused { return }
            }
            if thenFinish {
                phase = .finished
            }
        } else {
            playbackTask = Task { [weak self, lineDelay, clock] in
                for step in steps {
                    try? await clock.sleep(for: lineDelay, tolerance: nil)
                    guard let self, !Task.isCancelled else { return }
                    if self.applied(step) == .paused {
                        return
                    }
                }
                guard let self, !Task.isCancelled else { return }
                if thenFinish {
                    self.phase = .finished
                }
            }
        }
    }

    private enum StepOutcome {
        case advanced
        case paused
    }

    private func applied(_ step: WelcomeDemoStep) -> StepOutcome {
        switch step {
        case .line(let line):
            lines.append(line)
            return .advanced
        case .question(let question):
            lines.append(question.prompt)
            self.question = question
            phase = .awaitingReply
            return .paused
        }
    }
}
#endif
