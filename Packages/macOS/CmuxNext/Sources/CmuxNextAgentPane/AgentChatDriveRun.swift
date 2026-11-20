import AppKit
import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// One run between `drive.begin` and `drive.end`: the hover, the wheel ticks and the hold.
struct DriveRun {
    let params: AgentChatDriveControl.Params
    let begun: [String: JSONValue]
    var hover: [String: JSONValue] = ["held": false, "native": true, "reason": "no_target"]
    var delivered = 0
    var interrupted: String?
    var countersStart: [String: Double]?

    init(params: AgentChatDriveControl.Params, begun: [String: JSONValue]) {
        self.params = params
        self.begun = begun
    }

    @MainActor
    mutating func drive(view: AgentPaneView, input: AgentChatDriveInput, person: DrivePerson, release: DriveRelease) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let stop = ContinuousClock.now + .seconds(params.seconds)
        // The page types one character a frame from `begin`: the run lasts until it can have typed them all.
        typed = ContinuousClock.now + .milliseconds((params.type?.text.count ?? 0) * Self.typingFrameMilliseconds)
        countersStart = await input.startEngineCounters()
        guard params.target != nil else { return try await hold(until: stop, watching: person, since: started, release: release) }
        guard case .number(let x)? = begun["point"]?["x"], case .number(let y)? = begun["point"]?["y"] else {
            hover["reason"] = "no_point"
            return try await hold(until: stop, watching: person, since: started, release: release)
        }
        let point = CGPoint(x: x, y: y)
        hover["x"] = .number(x)
        hover["y"] = .number(y)
        // Armed before the move: a release that runs while the move is in flight still gives the hover back.
        release.armed = true
        guard await input.move(to: point) else {
            hover["reason"] = "move_failed"
            return try await hold(until: stop, watching: person, since: started, release: release)
        }
        await input.settle()
        guard !view.pageIsFrozen, let state = try await AgentChatDriveControl.call(view, AgentChatDriveControl.stateScript, [:], timeout: .seconds(5)),
              state["hovered"] == true else {
            hover["reason"] = "not_hovered"
            return try await hold(until: stop, watching: person, since: started, release: release)
        }
        hover["held"] = true
        hover.removeValue(forKey: "reason")
        if let wheel = params.wheel {
            for tick in 0..<wheel.ticks {
                // The person goes first: the moment they come back to the chat, stop and hand the pointer back.
                if person.isUsing(since: started) {
                    interrupted = "person"
                    await release.release("person")
                    return
                }
                guard !release.isDone, ContinuousClock.now < stop else { break }
                if await input.wheel(at: point, deltaY: Double(wheel.delta)) { delivered += 1 }
                if tick + 1 < wheel.ticks {
                    // wakeup-allow: the caller's tick spacing (8 to 200 ms, at most 200 ticks); cancelled with the call
                    try await Task.sleep(for: .milliseconds(wheel.tickMilliseconds))
                }
            }
        }
        try await hold(until: stop, watching: person, since: started, release: release)
    }

    /// A frame and a margin per character the page types (one a frame at 60 Hz).
    static let typingFrameMilliseconds = 20
    /// When the page can have typed all of `type.text`.
    private var typed = ContinuousClock.now

    /// Keeps the hover `hold_ms` after the last tick, and until the page can have typed its text, within
    /// the run's bound, watching for the person all the while: when they come back, the run hands the pointer back.
    private mutating func hold(until stop: ContinuousClock.Instant, watching person: DrivePerson, since started: TimeInterval,
                               release: DriveRelease) async throws {
        let now = ContinuousClock.now
        let end = min(max(now + .milliseconds(params.holdMilliseconds), typed), stop)
        guard try await DriveWatch.watch(until: end, isUsing: { person.isUsing(since: started) }) else { return }
        interrupted = "person"
        await release.release("person")
    }
}

/// A wait that watches for the person: it sleeps in short steps and checks between them.
struct DriveWatch {
    /// The longest step between two checks.
    static let step = Duration.milliseconds(100)

    /// Waits until `end`, checking `isUsing` before each step of at most `step` and at the end; true
    /// (at once) when it said the person is back, false when the wait ran out without them.
    static func watch(until end: ContinuousClock.Instant, step: Duration = step, isUsing: () -> Bool) async throws -> Bool {
        while ContinuousClock.now < end {
            if isUsing() { return true }
            // wakeup-allow: one step (at most 100 ms) of a bounded hold (at most 30 s), cancelled with the call
            try await Task.sleep(for: min(step, end - ContinuousClock.now))
        }
        return isUsing()
    }
}
