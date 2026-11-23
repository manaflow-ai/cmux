import CmuxNextCompat
public import Foundation
public import os

/// A composer Cloud send, timed from the Send to the agent's first token (cmux#45953: "the whole thing, send to the
/// model's first response token, must be under 3 s, not just setup"). The start marks each step as it ends
/// (``mark(_:)``): the preflight, the machine (its plan, connect and route), the copy and the approvals that run beside
/// it, the gateway, the chat's workspace and tab, then the new chat's page: its first prompt out
/// (`prompt`), the machine's agent start answered (`start`, with the daemon's own phases in ``setMachine(_:)``) and the
/// agent's first text (`first token`). Each step runs from the one before it to its own end, so the steps add up to the
/// span, and the one line (``prefix``) says which step took the time and whether the span met ``targetMs``. Names and
/// milliseconds only, never an id, a path, a prompt or a token. Marked from any thread: the page's wire marks its steps
/// as its frames pass, with no hop to the main actor.
public final class CloudSendTimeline: Sendable {
    /// What the one line starts with.
    public static let prefix = "cloud send to first token: "
    /// cmux#45953's target for the whole span.
    public static let targetMs = 3_000
    /// The last step: its mark ends the timeline.
    public static let firstToken = "first token"

    private struct State {
        var marks: [(step: String, at: Int)] = []
        var machine: [String: Int]?
        var finished = false
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private let began: ContinuousClock.Instant
    private let state = Mutex(State())

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        began = now()
    }

    /// Each step's end, in milliseconds since the Send, in the order the steps ended; a step marked twice keeps its first end.
    public var marks: [(step: String, at: Int)] { state.withLock { $0.marks } }
    /// Set once ``firstToken`` was marked: later marks are dropped.
    public var finished: Bool { state.withLock { $0.finished } }

    /// The machine's own phases of the agent start (`timings_ms`), when its daemon sent them.
    public func setMachine(_ phases: [String: Int]?) {
        guard let phases else { return }
        state.withLock { $0.machine = phases }
    }

    /// Marks `step` as ended now; answers the one line when `step` is ``firstToken``.
    @discardableResult
    public func mark(_ step: String) -> String? {
        let at = Int(CloudStartSteps.milliseconds(began.duration(to: now())))
        return state.withLock { state in
            guard !state.finished, !state.marks.contains(where: { $0.step == step }) else { return nil }
            state.marks.append((step, at))
            guard step == Self.firstToken else { return nil }
            state.finished = true
            return Self.line(state.marks, machine: state.machine)
        }
    }

    /// Each step's own time: from the step that ended before it (or the Send) to its end.
    public static func steps(_ marks: [(step: String, at: Int)]) -> [(step: String, ms: Int)] {
        var last = 0
        return marks.map { mark in
            defer { last = max(last, mark.at) }
            return (mark.step, max(0, mark.at - last))
        }
    }

    /// `cloud send to first token: TOTAL ms; STEP MS, ...; machine PHASE MS, ...; met|over the 3000 ms target ...`.
    public static func line(_ marks: [(step: String, at: Int)], machine: [String: Int]?) -> String {
        let steps = steps(marks), total = marks.map(\.at).max() ?? 0
        var parts = ["\(prefix)\(total) ms", steps.map { "\($0.step) \($0.ms)" }.joined(separator: ", ")]
        let phases = ["acpmux_connect", "checks", "session_new", "settle", "bind"].compactMap { name in machine?[name].map { "\(name) \($0)" } }
        if !phases.isEmpty { parts.append("machine " + phases.joined(separator: ", ")) }
        parts.append(verdict(total: total, steps: steps))
        return parts.joined(separator: "; ")
    }

    /// Whether `total` met ``targetMs``; over it, by how much and the step that took the most.
    public static func verdict(total: Int, steps: [(step: String, ms: Int)]) -> String {
        guard total > targetMs else { return "met the \(targetMs) ms target" }
        let most = steps.max { $0.ms < $1.ms }
        return "over the \(targetMs) ms target by \(total - targetMs) ms" + (most.map { ", most in \($0.step) (\($0.ms) ms)" } ?? "")
    }
}

/// The composer sends being timed (``CloudSendTimeline``), found again by the new chat's tab on its machine once the
/// start opened it there (``bind(_:machine:tabs:)``), so the chat's page marks its own steps on the start's timeline.
/// One per app, made by the Cloud service and passed to the start and the chat's tab. At most ``kept`` tabs at once: a
/// send whose chat never answers is dropped with the oldest, never kept forever.
public final class CloudSendTimelines: Sendable {
    public static let kept = 16
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.start")

    private let bound = Mutex<[(key: String, timeline: CloudSendTimeline)]>([])

    public init() {}

    /// The timeline of the chat tab `tab` on `machine`, while its send is being timed.
    public func timeline(machine: String, tab: String) -> CloudSendTimeline? {
        let key = Self.key(machine, tab)
        return bound.withLock { bound in bound.first { $0.key == key }?.timeline }
    }

    /// The chat's tab on `machine` (each of `tabs`: its creation key and its store id) marks on `timeline` from now on.
    public func bind(_ timeline: CloudSendTimeline, machine: String, tabs: [String]) {
        bound.withLock { bound in
            for tab in Set(tabs) where !tab.isEmpty {
                let key = Self.key(machine, tab)
                bound.removeAll { $0.key == key }
                bound.append((key, timeline))
            }
            while bound.count > Self.kept { bound.removeFirst() }
        }
    }

    /// Marks `step` on the timeline of `tab` on `machine`, if one is being timed, with the machine's own start phases
    /// when given; the first token logs the one line and ends the timeline.
    public func mark(_ step: String, machine: String, tab: String, phases: [String: Int]? = nil) {
        guard let timeline = timeline(machine: machine, tab: tab) else { return }
        timeline.setMachine(phases)
        guard let line = timeline.mark(step) else { return }
        Self.logger.info("\(line, privacy: .public)")
        bound.withLock { bound in bound.removeAll { $0.timeline === timeline } }
    }

    private static func key(_ machine: String, _ tab: String) -> String { machine + "\u{1F}" + tab }
}
