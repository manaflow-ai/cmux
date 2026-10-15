import Foundation

/// HomeStore's live run state, built from `HomeLiveEvent`s (shared by every
/// Home view; the views only draw `HomeStore.live`). Keyed by conversation,
/// author and run: run ids repeat across Chiefs. Rules (hq-1f DESIGN.md
/// "Live frames"):
/// - a step's `seq` starts at 0 and grows by one; a frame not above the last
///   one is a repeat; a jump, or text of a step this client never saw from
///   0, asks the owner again (`resync`) and the `run.live` answer replaces
///   the conversation's runs; a `seq` 0 for a known step restarts its text;
/// - a step whose row came drops later deltas but keeps its text on screen
///   until the reply lands, so the bubble never shrinks before the message;
/// - its posted reply (same author, `client_msg_id` = the run's turn) ends
///   it; a run that ends `done` with reply text keeps that text (no activity)
///   until its reply lands, so the bubble never leaves before the message
///   takes its place (also when the run record comes first), and the next
///   message or run of that Chief ends it; `failed` or `cancelled` ends it at
///   once. Late frames of an ended run never bring it back; activity frames
///   never end a run.
struct HomeLiveBook {
    enum Outcome: Equatable {
        case ignored
        case changed
        /// A frame was missed: ask the owner for its `run.live` snapshot.
        case resync
    }

    struct Key: Hashable {
        var conversation: ConversationID
        var author: ParticipantID
        var run: String
    }

    struct Step: Equatable {
        var isTalk: Bool
        var seq: UInt64
        var text: String
    }

    struct Run: Equatable {
        var steps: [String: Step] = [:]
        /// Step ids in the order their text began.
        var order: [String] = []
        /// Steps whose row came or whose last thought frame came.
        var done: Set<String> = []
        var activity: HomeLiveActivity?
        var touched = 0
        /// The run ended `done`: its text waits for the reply.
        var awaitingReply = false

        var hasTalk: Bool { order.contains { steps[$0]?.isTalk == true } }
    }

    private(set) var runs: [Key: Run] = [:]
    /// Run.turn by run (from run records); the local Chief's run id is its turn.
    private var turns: [Key: IdempotencyKey] = [:]
    /// Ended runs, newest last (bounded): their late frames are dropped.
    private var ended: [Key] = []
    private var tick = 0
    static let endedLimit = 512
    /// The owner keeps 64 KiB of tail text per step; so does this.
    static let stepCap = 64 * 1024

    mutating func apply(_ event: HomeLiveEvent, author resolve: (ParticipantID?) -> ParticipantID?) -> Outcome {
        switch event {
        case .delta(let delta):
            guard let author = resolve(delta.author) else { return .ignored }
            return apply(delta, key: Key(conversation: delta.conversation, author: author, run: delta.run))
        case .activity(let frame):
            guard let author = resolve(frame.author) else { return .ignored }
            let key = Key(conversation: frame.conversation, author: author, run: frame.run)
            guard !ended.contains(key) else { return .ignored }
            var run = runs[key] ?? Run()
            guard run.activity != frame.activity else { return .ignored }
            run.activity = frame.activity
            run.touched = touch()
            runs[key] = run
            return .changed
        case .snapshot(let conversation, let entries):
            // Runs that ended `done` are not in a snapshot: their text still waits for the reply.
            var next = runs.filter { $0.key.conversation != conversation || $0.value.awaitingReply }
            for entry in entries {
                guard let author = resolve(entry.author) else { continue }
                let key = Key(conversation: conversation, author: author, run: entry.run)
                guard !ended.contains(key) else { continue }
                var run = Run(activity: entry.activity, touched: touch())
                run.done = runs[key]?.done ?? []
                for step in entry.steps {
                    // A finished step keeps the text this client already shows.
                    if run.done.contains(step.step), let kept = runs[key]?.steps[step.step] {
                        run.steps[step.step] = kept
                    } else if !run.done.contains(step.step) {
                        run.steps[step.step] = Step(isTalk: step.isTalk, seq: step.seq, text: Self.capped(step.text))
                    } else {
                        continue
                    }
                    run.order.append(step.step)
                }
                next[key] = run
            }
            guard next != runs else { return .ignored }
            runs = next
            return .changed
        case .run(let change):
            let key = Key(conversation: change.conversation, author: change.author, run: change.run)
            if let turn = change.turn { turns[key] = turn }
            if change.status == "done", runs[key]?.awaitingReply == true { return .ignored }
            if change.status == "done", var run = runs[key], run.hasTalk {
                run.awaitingReply = true
                run.activity = nil
                runs[key] = run
                remember(key)
                return .changed
            }
            guard change.status == "running" else { return end(key) ? .changed : .ignored }
            guard !ended.contains(key) else { return .ignored }
            // A new run of this Chief: a reply its earlier run waits for is not coming.
            var changed = false
            for other in runs.keys where other.conversation == key.conversation && other.author == key.author
                && other != key && runs[other]?.awaitingReply == true {
                changed = end(other) || changed
            }
            guard var run = runs[key] else { return changed ? .changed : .ignored }
            let finished = change.finishedSteps.filter { !run.done.contains($0) }
            guard !finished.isEmpty else { return changed ? .changed : .ignored }
            run.done.formUnion(finished)
            runs[key] = run
            return changed ? .changed : .ignored // the text stays as it is until the reply lands
        }
    }

    private mutating func apply(_ delta: HomeLiveDelta, key: Key) -> Outcome {
        guard !ended.contains(key) else { return .ignored }
        var run = runs[key] ?? Run()
        guard !run.done.contains(delta.step) else { return .ignored }
        if var step = run.steps[delta.step] {
            if delta.seq == 0 {
                // A retried model request restarts the step (the owner also sends run.live).
                step = Step(isTalk: delta.isTalk, seq: 0, text: Self.capped(delta.text))
            } else if delta.seq <= step.seq {
                return .ignored
            } else if delta.seq == step.seq + 1 {
                step.seq = delta.seq
                step.text = Self.capped(step.text + delta.text)
            } else {
                return .resync
            }
            run.steps[delta.step] = step
        } else if delta.seq == 0 {
            run.steps[delta.step] = Step(isTalk: delta.isTalk, seq: 0, text: Self.capped(delta.text))
            run.order.append(delta.step)
        } else {
            // Joined mid-step: the snapshot has the text before this frame.
            return .resync
        }
        // A thought has no row on Cloud: its final frame ends it.
        if delta.isFinal, !delta.isTalk {
            run.steps[delta.step] = nil
            run.order.removeAll { $0 == delta.step }
            run.done.insert(delta.step)
        }
        run.touched = touch()
        runs[key] = run
        return .changed
    }

    /// A message was committed: the run whose reply it is ends.
    mutating func posted(_ message: Message) -> Bool {
        let mine = runs.keys.filter { $0.conversation == message.conversation && $0.author == message.author }
        var changed = false
        for key in mine where turn(of: key) == message.clientMessageID || runs[key]?.awaitingReply == true {
            changed = end(key) || changed
        }
        return changed
    }

    private func turn(of key: Key) -> IdempotencyKey { turns[key] ?? IdempotencyKey(key.run) }

    private mutating func end(_ key: Key) -> Bool {
        let had = runs.removeValue(forKey: key) != nil
        turns[key] = nil
        remember(key)
        return had
    }

    /// Late frames of `key` are dropped from now on.
    private mutating func remember(_ key: Key) {
        guard !ended.contains(key) else { return }
        ended.append(key)
        if ended.count > Self.endedLimit { ended.removeFirst(ended.count - Self.endedLimit) }
    }

    /// What each conversation shows: its most recently touched run with reply
    /// text or an activity line.
    var shown: [ConversationID: HomeLiveRun] {
        var best: [ConversationID: (Key, Run)] = [:]
        for (key, run) in runs where run.activity != nil || run.hasTalk {
            if let current = best[key.conversation], current.1.touched >= run.touched { continue }
            best[key.conversation] = (key, run)
        }
        return best.mapValues { pair in
            let (key, run) = pair
            let talk = run.order.enumerated().filter { run.steps[$0.element]?.isTalk == true }
                .sorted { (Self.segment($0.element), $0.offset) < (Self.segment($1.element), $1.offset) }
                .compactMap { run.steps[$0.element]?.text }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return HomeLiveRun(participant: key.author, run: key.run, turn: turn(of: key),
                               text: talk.joined(separator: "\n\n"), activity: run.activity)
        }
    }

    private mutating func touch() -> Int {
        tick += 1
        return tick
    }

    /// `talk:3` -> 3; other ids after every numbered one, in begin order (a stable sort).
    private static func segment(_ step: String) -> Int {
        guard step.hasPrefix("talk:"), let n = Int(step.dropFirst(5)) else { return Int.max }
        return n
    }

    static func capped(_ text: String) -> String {
        let units = text.utf16
        guard units.count > stepCap else { return text }
        var start = units.index(units.endIndex, offsetBy: -stepCap)
        if UTF16.isTrailSurrogate(units[start]) { start = units.index(after: start) }
        return "…" + String(text[start...])
    }
}
