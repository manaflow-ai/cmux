import Foundation

/// HomeStore's live run state, built from `HomeLiveEvent`s (shared by every
/// Home view; the views only draw `HomeStore.live`). Keyed by conversation,
/// author and run: run ids repeat across Chiefs. Rules (hq-1f DESIGN.md
/// "Live frames"):
/// - a step's `seq` starts at 0 and grows by one; a frame not above the last
///   one is a repeat; a jump, or text of a step this client never saw from
///   0, asks the owner again (`resync`) and the `run.live` answer replaces
///   the conversation's runs; a `seq` 0 for a known step restarts its text;
/// - a step's `final` frame ends it: later deltas are dropped, a talk step
///   keeps its text on screen until the reply lands (the bubble never shrinks
///   before the message); the activity line stays until the run's reply lands
///   (its row leaving earlier would move the bubble just before the hand-off);
///   a snapshot no longer lists an ended step, so its text is kept from here;
/// - a snapshot never takes a step back: a step this client holds at the same
///   or a later `seq` with the snapshot's text as its start stays;
/// - its posted reply (same author, `client_msg_id` = the run's turn) ends
///   it; a run that ends `done` with reply text keeps that text (no activity)
///   until its reply lands, so the bubble never leaves before the message
///   takes its place (also when the run record comes first), and the next
///   message of that Chief ends it (a new run does not: its reply is still coming); `failed` or `cancelled` ends it at
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
        /// Seeded from the step's row (a join): its frames' numbering is unknown, so a later
        /// frame other than seq 0 asks for the snapshot instead of appending.
        var fromRow = false
        /// Its place in the run: the owner's `Step.seq` from its row (set once, kept on change; local
        /// and Cloud brains alike, TRAJECTORIES.md). Nil until a row came: after every placed step.
        var place: UInt64?
    }

    struct Run: Equatable {
        var steps: [String: Step] = [:]
        /// Step ids in the order their text began.
        var order: [String] = []
        /// Steps whose row came or whose last thought frame came.
        var done: Set<String> = []
        var activity: HomeLiveActivity?
        var touched = 0
        /// When the run began on this client (a snapshot keeps it): the streams' display order.
        var begun = 0
        /// The run ended `done`: its text waits for the reply.
        var awaitingReply = false
        /// The newest thought's text, kept after its step ended (a thought's final frame drops the step):
        /// the run's progress narration until the next thought.
        var lastThought: String?

        var hasTalk: Bool { order.contains { steps[$0]?.isTalk == true } }
    }

    private(set) var runs: [Key: Run] = [:]
    /// Run.turn by run (from run records); the local Chief's run id is its turn.
    private var turns: [Key: IdempotencyKey] = [:]
    /// Ended runs, newest last (bounded): their late frames are dropped.
    private var ended: [Key] = []
    private var tick = 0
    private var beginTick = 0
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
            var run = runs[key] ?? newRun()
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
                let old = runs[key]
                var run = Run(activity: entry.activity, touched: touch())
                run.begun = old?.begun ?? begin()
                run.done = old?.done ?? []
                run.lastThought = entry.steps.last { !$0.isTalk }?.text ?? old?.lastThought
                // Ended steps the owner freed, and steps seeded from rows, keep the text this client holds.
                let listed = Set(entry.steps.map(\.step))
                for id in old?.order ?? [] where run.done.contains(id) || (old?.steps[id]?.fromRow == true && !listed.contains(id)) {
                    guard let kept = old?.steps[id] else { continue }
                    run.steps[id] = kept
                    run.order.append(id)
                }
                for step in entry.steps where !run.done.contains(step.step) {
                    var fresh = Step(isTalk: step.isTalk, seq: step.seq, text: Self.capped(step.text))
                    fresh.place = old?.steps[step.step]?.place ?? step.place
                    if let held = old?.steps[step.step], held.seq >= step.seq, held.text.hasPrefix(fresh.text) {
                        run.steps[step.step] = held // an older answer than the deltas this client applied
                    } else {
                        run.steps[step.step] = fresh
                    }
                    if !run.order.contains(step.step) { run.order.append(step.step) }
                }
                next[key] = run
            }
            guard next != runs else { return .ignored }
            runs = next
            return .changed
        case .rows(let conversation, let author, let run, let rows):
            // A talk step the run does not hold (not in run.live, no delta seen) with a row: it ended
            // before this client joined (the owner freed it), or it streams but its first frame has
            // not come yet (a Chief writes open rows too). Its row is its text so far; it stays open:
            // a seq-0 frame replaces it, a later frame asks for the snapshot (cx-kdm25).
            let key = Key(conversation: conversation, author: author, run: run)
            guard !ended.contains(key), var live = runs[key] else { return .ignored }
            var changed = false
            for row in rows where row.isTalk {
                // A step this client holds takes its place from its row (cx-5ylym).
                if var held = live.steps[row.step] {
                    if let place = row.place, held.place != place { held.place = place; live.steps[row.step] = held; changed = true }
                    continue
                }
                guard !live.done.contains(row.step), !row.text.isEmpty else { continue }
                live.steps[row.step] = Step(isTalk: true, seq: 0, text: Self.capped(row.text), fromRow: true, place: row.place)
                live.order.append(row.step)
                changed = true
            }
            guard changed else { return .ignored }
            runs[key] = live
            return .changed
        case .run(let change):
            let key = Key(conversation: change.conversation, author: change.author, run: change.run)
            if let turn = change.turn { turns[key] = turn }
            if change.status == "done", runs[key]?.awaitingReply == true { return .ignored }
            if change.status == "done", var run = runs[key], run.hasTalk {
                // The line keeps its row until the reply took the bubble's place (the view closes it after).
                run.awaitingReply = true
                runs[key] = run
                remember(key)
                return .changed
            }
            guard change.status == "running" else { return end(key) ? .changed : .ignored }
            // A new run does not end a run that waits for its reply (B4,
            // plans/cmux-next/home-chat-pipeline-DESIGN.md): that reply is still coming, and its
            // bubble stays until it lands (or the Chief's next message, `posted`). Step rows end
            // nothing: the local Chief writes an open talk row while the step still streams; a step
            // ends with its `final` frame.
            return .ignored
        }
    }

    private mutating func apply(_ delta: HomeLiveDelta, key: Key) -> Outcome {
        guard !ended.contains(key) else { return .ignored }
        var run = runs[key] ?? newRun()
        guard !run.done.contains(delta.step) else { return .ignored }
        if var step = run.steps[delta.step] {
            if step.fromRow, delta.seq > 0 {
                return .resync // a row's text has no frame number: the snapshot has this step
            }
            if delta.seq == 0 {
                // A retried model request restarts the step (the owner also sends run.live).
                step = Step(isTalk: delta.isTalk, seq: 0, text: Self.capped(delta.text), place: step.place)
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
        if !delta.isTalk, let text = run.steps[delta.step]?.text { run.lastThought = text }
        if delta.isFinal {
            run.done.insert(delta.step)
            if !delta.isTalk {
                run.steps[delta.step] = nil
                run.order.removeAll { $0 == delta.step }
            }
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

    /// Every live run of `conversation` with the key its reply will carry.
    func turns(in conversation: ConversationID) -> [(Key, IdempotencyKey)] {
        runs.keys.filter { $0.conversation == conversation }.map { ($0, turn(of: $0)) }
    }

    mutating func end(_ key: Key) -> Bool {
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
        return best.mapValues { liveRun($0.0, $0.1) }
    }

    /// Every run of `conversation` with reply text, in the order the runs began: each is one
    /// running reply (one bubble) until its reply lands (several can run at once: two Chiefs in a
    /// group, a new turn while the last one's reply is on its way).
    func streams(in conversation: ConversationID) -> [HomeLiveRun] {
        runs.filter { $0.key.conversation == conversation && $0.value.hasTalk }
            .sorted { ($0.value.begun, $0.key.run) < ($1.value.begun, $1.key.run) }
            .map { liveRun($0.key, $0.value) }
            .filter { !$0.text.isEmpty }
    }

    private func liveRun(_ key: Key, _ run: Run) -> HomeLiveRun {
        let talk = run.order.enumerated().filter { run.steps[$0.element]?.isTalk == true }
            .sorted { (Self.place(run.steps[$0.element]), $0.offset) < (Self.place(run.steps[$1.element]), $1.offset) }
            .compactMap { run.steps[$0.element]?.text }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let thought = run.lastThought?.thoughtHeadline
        return HomeLiveRun(participant: key.author, run: key.run, turn: turn(of: key),
                           text: talk.joined(separator: "\n\n"), activity: run.activity, thought: thought)
    }

    private mutating func newRun() -> Run {
        var run = Run()
        run.begun = begin()
        return run
    }

    private mutating func begin() -> Int {
        beginTick += 1
        return beginTick
    }

    private mutating func touch() -> Int {
        tick += 1
        return tick
    }

    /// A step's sort key: its owner-set place (`Step.seq`); a step with no row yet after every placed
    /// one, in begin order (cx-5ylym: never parse the id; Cloud ids are `talk:<generation task id>`).
    private static func place(_ step: Step?) -> UInt64 { step?.place ?? .max }

    static func capped(_ text: String) -> String {
        let units = text.utf16
        guard units.count > stepCap else { return text }
        var start = units.index(units.endIndex, offsetBy: -stepCap)
        if UTF16.isTrailSurrogate(units[start]) { start = units.index(after: start) }
        return "…" + String(text[start...])
    }
}
