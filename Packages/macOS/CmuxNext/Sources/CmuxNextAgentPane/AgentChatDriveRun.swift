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
    /// Wheel ticks handed to the engine.
    var sent = 0
    /// How far the transcript moved from just before the first tick to just after the last (CSS px).
    var scrolled: Double?
    var interrupted: String?
    var countersStart: [String: Double]?

    init(params: AgentChatDriveControl.Params, begun: [String: JSONValue]) {
        self.params = params
        self.begun = begun
    }

    @MainActor
    mutating func drive(view: AgentPaneView, input: AgentChatDriveInput, person: DrivePerson, surroundings: DriveSurroundings,
                        release: DriveRelease) async throws {
        self.surroundings = surroundings
        let started = ProcessInfo.processInfo.systemUptime
        let stop = ContinuousClock.now + .seconds(params.seconds)
        // The page types one character a frame from `begin`: the run lasts until it can have typed them all.
        typed = ContinuousClock.now + .milliseconds((params.type?.text.count ?? 0) * Self.typingFrameMilliseconds)
        // Armed before anything awaits: the person's pointer can end the release while the counters start,
        // and an unarmed release counts as done at once, which would leave the hover below with none.
        if params.target != nil { release.armed = true }
        countersStart = await input.startEngineCounters()
        guard params.target != nil else { return try await hold(until: stop, watching: person, since: started, release: release) }
        guard case .number(let x)? = begun["point"]?["x"], case .number(let y)? = begun["point"]?["y"] else {
            hover["reason"] = "no_point"
            return try await hold(until: stop, watching: person, since: started, release: release)
        }
        let point = CGPoint(x: x, y: y)
        hover["x"] = .number(x)
        hover["y"] = .number(y)
        // Armed (above) before the move: a release that runs while the move is in flight still gives the
        // hover back. One that already started (the person, a trigger, the backstop) means no hover is made at all.
        guard release.mayHover else {
            hover["reason"] = "released"
            interrupted = release.interruption ?? "person"
            return
        }
        guard await input.move(to: point) else {
            hover["reason"] = "move_failed"
            return try await hold(until: stop, watching: person, since: started, release: release)
        }
        await input.settle()
        // timeout: only how long the run waits for a stalled page to say whether the hover took; the run then ends as an error that still asks for the report and releases the hover
        guard !view.pageIsFrozen, let state = try await AgentChatDriveControl.call(view, AgentChatDriveControl.stateScript, [:], timeout: .seconds(5)),
              state["hovered"] == true else {
            hover["reason"] = "not_hovered"
            return try await hold(until: stop, watching: person, since: started, release: release)
        }
        hover["held"] = true
        hover.removeValue(forKey: "reason")
        if let wheel = params.wheel {
            let before = try await Self.scrollTop(view)
            let stopped = try await wheelTicks(wheel, at: point, view: view, input: input, person: person, release: release,
                                               started: started, stop: stop)
            // The page's own scroll, once WebKit has handled what was sent: what the ticks really moved. The wait
            // ends at `stop` too (an occluded window would run both its bounds); with none left, the page is read as is.
            await input.settle(before: stop)
            if let before, let after = try await Self.scrollTop(view) { scrolled = after - before }
            if stopped { return }
        }
        try await hold(until: stop, watching: person, since: started, release: release)
    }

    /// Sends `wheel`'s ticks at `point`, watching for the person, the window and the app between them.
    /// True when one of them stopped the run (`interrupted` says which; the release has started).
    private mutating func wheelTicks(_ wheel: AgentChatDriveControl.Params.Wheel, at point: CGPoint, view: AgentPaneView,
                                     input: AgentChatDriveInput, person: DrivePerson, release: DriveRelease,
                                     started: TimeInterval, stop: ContinuousClock.Instant) async throws -> Bool {
        for tick in 0..<wheel.ticks {
            // A trigger from outside the run (the tab or window closing, the app resigning) already released.
            if let trigger = Self.outside(surroundings, release) {
                interrupted = trigger
                return true
            }
            // The person goes first: the moment they come back to the chat, stop and hand the pointer back.
            if person.isUsing(since: started) {
                interrupted = "person"
                await release.release("person")
                return true
            }
            guard !release.isDone, ContinuousClock.now < stop else { break }
            // A tick's waits for WebKit end at `stop` too: on a covered window each would run its whole bound.
            if await input.wheel(at: point, deltaY: Double(wheel.delta), before: stop) { sent += 1 }
            if tick + 1 < wheel.ticks {
                // Between two ticks (up to 200 ms apart, never past `stop`) the person, the window and the app
                // are watched every DriveWatch.step, as in a hold; what it sees, the next tick's checks act on at once.
                let surroundings = surroundings
                _ = try await DriveWatch.watch(until: min(ContinuousClock.now + .milliseconds(wheel.tickMilliseconds), stop), isUsing: {
                    Self.outside(surroundings, release) != nil || person.isUsing(since: started)
                })
            }
        }
        return false
    }

    /// The transcript's scroll offset as the page reads it (`drive.state().scroll_top`), or nil.
    static func scrollTop(_ view: AgentPaneView) async throws -> Double? {
        guard !view.pageIsFrozen else { return nil }
        // timeout: only how long the run waits for a stalled page's scroll offset; the run then ends as an error that still asks for the report and releases the hover
        return try await AgentChatDriveControl.call(view, AgentChatDriveControl.stateScript, [:], timeout: .seconds(5))?["scroll_top"]?.doubleValue
    }

    /// What the run is driven in, read with the person (set by ``drive(view:input:person:surroundings:release:)``).
    private var surroundings: DriveSurroundings?

    /// The trigger from outside the run, if any: one `release` already heard, or one `surroundings`
    /// sees now, which it tells `release` (it starts releasing at once).
    static func outside(_ surroundings: DriveSurroundings?, _ release: DriveRelease) -> String? {
        if release.triggered == nil, let trigger = surroundings?.trigger() { release.trigger(trigger) }
        return release.triggered
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
        let surroundings = surroundings
        guard try await DriveWatch.watch(until: end, isUsing: {
            Self.outside(surroundings, release) != nil || person.isUsing(since: started)
        }) else { return }
        // A trigger from outside the run released already; else the person is back.
        guard release.triggered == nil else {
            interrupted = release.triggered
            return
        }
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
