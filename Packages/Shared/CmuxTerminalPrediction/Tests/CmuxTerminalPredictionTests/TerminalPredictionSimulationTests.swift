import Testing
@testable import CmuxTerminalPrediction

// A randomized, seeded simulation of the whole prediction loop: a user typing
// and backspacing, a link with latency, a remote line editor echoing like bash
// readline, ghostty's parser and renderer, and the host that drains output
// and re-anchors the overlay. After every event it checks that each glyph the
// overlay draws lands on the cell its character actually occupies.

/// Deterministic generator, so a failing seed replays exactly.
struct SimulationRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum SimulatedKey: Equatable, CustomStringConvertible {
    case character(UInt8)
    case backspace

    var description: String {
        switch self {
        case .character(let byte): String(UnicodeScalar(byte))
        case .backspace: "⌫"
        }
    }
}

/// One keystroke and every random choice that follows from it, so a case
/// shrinks by deleting keystrokes without disturbing the others' timing.
struct SimulatedKeystroke {
    var key: SimulatedKey
    /// Microseconds after the previous keystroke.
    var gap: Int
    /// Keystroke to remote, and remote output back, in microseconds.
    var uplink: Int
    var downlink: Int
    /// Seeds the read boundaries of this keystroke's echo and the host's
    /// drain and render delays after each read.
    var jitterSeed: UInt64
}

/// How the remote line editor erases one character at the end of the line.
enum SimulatedEraseForm: CaseIterable {
    /// bash readline with TERM=xterm-ghostty, as captured on big-red.
    case backspaceClearToEnd
    /// Canonical tty echo.
    case backspaceSpaceBackspace
    case cursorLeftDeleteCharacter

    var bytes: [UInt8] {
        switch self {
        case .backspaceClearToEnd: [0x08, 0x1B, 0x5B, 0x4B]
        case .backspaceSpaceBackspace: [0x08, 0x20, 0x08]
        case .cursorLeftDeleteCharacter: [0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x50]
        }
    }
}

struct SimulationCase {
    var keystrokes: [SimulatedKeystroke]
    var eraseForm: SimulatedEraseForm
    /// Readline and zle skip redisplay while more input is pending, so keys
    /// that reach the remote together come back as one redraw of the net
    /// change: back to where the lines diverge, the new tail, then `CSI K`
    /// if the line got shorter. A typo and its erase can echo nothing.
    var coalescesTypeahead = false
}

/// The remote's line: what bash readline holds after the keys it has read.
struct SimulatedLineEditor {
    static let prompt = Array("leo@big-red:~$ ".utf8)
    var line: [UInt8] = []

    /// Applies a key and returns what the remote writes back.
    mutating func read(_ key: SimulatedKey, eraseForm: SimulatedEraseForm) -> [UInt8] {
        switch key {
        case .character(let byte):
            line.append(byte)
            return [byte]
        case .backspace:
            guard !line.isEmpty else { return [0x07] }
            line.removeLast()
            return eraseForm.bytes
        }
    }

    /// The row as it looks once every key read so far is echoed.
    var row: [UInt8] { Self.prompt + line }

    /// Applies keys read together and returns one redisplay of the net change.
    mutating func readTogether(_ keys: [SimulatedKey]) -> [UInt8] {
        let before = line
        for key in keys {
            switch key {
            case .character(let byte): line.append(byte)
            case .backspace: if !line.isEmpty { line.removeLast() }
            }
        }
        var common = 0
        while common < before.count, common < line.count, before[common] == line[common] { common += 1 }
        var output = [UInt8](repeating: 0x08, count: before.count - common)
        output += line[common...]
        if line.count < before.count { output += [0x1B, 0x5B, 0x4B] }
        return output
    }
}

/// Just enough of a terminal to track the cursor row: printables, BS, BEL,
/// and CSI K, D and P with the counts a line editor uses.
struct SimulatedScreen {
    private(set) var row: [UInt8] = SimulatedLineEditor.prompt
    private(set) var cursor = SimulatedLineEditor.prompt.count
    private var escape: [UInt8]?

    func character(at column: Int) -> UInt8? {
        column >= 0 && column < row.count ? row[column] : nil
    }

    mutating func apply(_ bytes: [UInt8]) {
        for byte in bytes { apply(byte) }
    }

    private mutating func apply(_ byte: UInt8) {
        if var sequence = escape {
            sequence.append(byte)
            guard sequence.count >= 2, (0x40...0x7E).contains(byte) else {
                escape = sequence
                return
            }
            escape = nil
            let count = max(1, Int(String(decoding: sequence.dropFirst().dropLast(), as: UTF8.self)) ?? 1)
            switch byte {
            case UInt8(ascii: "K"):
                if cursor < row.count { row.removeSubrange(cursor...) }
            case UInt8(ascii: "D"):
                cursor = max(0, cursor - count)
            case UInt8(ascii: "P"):
                if cursor < row.count { row.removeSubrange(cursor..<min(row.count, cursor + count)) }
            default:
                break
            }
            return
        }
        switch byte {
        case 0x1B:
            escape = []
        case 0x08:
            cursor = max(0, cursor - 1)
        case 0x07:
            break
        case 0x20...0x7E:
            while row.count <= cursor { row.append(0x20) }
            row[cursor] = byte
            cursor += 1
        default:
            break
        }
    }
}

struct SimulationFailure: Error, CustomStringConvertible {
    var message: String
    var trace: [String]
    var description: String { ([message] + trace).joined(separator: "\n") }
}

/// Plays one case through the engine and a model of the host around it.
struct PredictionSimulation {
    private enum Event {
        case keystroke(Int)
        /// A read from the PTY: the tee and ghostty's parser see it at once.
        case read([UInt8], drainDelay: Int, renderDelay: Int)
        /// The main actor drains the tee's inbox into the engine.
        case drain
        /// A rendered frame reaches the main actor.
        case frame
    }

    private struct Scheduled {
        var time: Int
        var order: Int
        var event: Event
    }

    private struct DrawnGlyph {
        var column: Int
        var character: Character
        var standing: PredictedGlyph.Standing
    }

    let simulationCase: SimulationCase
    private var engine = TerminalPredictionEngine(isEnabled: true)
    private var queue: [Scheduled] = []
    private var order = 0
    private var screen = SimulatedScreen()
    /// The screen as far as the engine has read it.
    private var screenSeenByEngine = SimulatedScreen()
    /// What the remote will show once every key typed so far is echoed.
    private var intended = SimulatedLineEditor()
    private var inbox: [(time: Int, bytes: [UInt8])] = []
    private var isDrainScheduled = false
    private var isFrameScheduled = false
    /// Presented-frame delivery, on only while the overlay holds glyphs.
    private var isTrackingFrames = false
    private var expiryTask: Int?
    /// What the overlay shows, anchored at the cursor when it last synced.
    private var overlay: [DrawnGlyph] = []
    private(set) var trace: [String] = []
    /// Events after which the overlay drew a speculative glyph, so a pass
    /// cannot come from a simulation that never predicts.
    private(set) var predictedEvents = 0

    init(_ simulationCase: SimulationCase) {
        self.simulationCase = simulationCase
    }

    private static func instant(_ micros: Int) -> PredictionInstant { .microseconds(micros) }

    private mutating func schedule(_ event: Event, at time: Int) {
        queue.append(Scheduled(time: time, order: order, event: event))
        order += 1
    }

    /// Lays out the keystrokes and the remote's replies. The remote reads in
    /// order and the link preserves order, so both are fixed in advance.
    private mutating func scheduleInputs() {
        var remote = SimulatedLineEditor()
        var typedAt = 0
        var readAt = 0
        var repliedAt = 0
        // Keys reaching the remote within this of the first in a group are
        // pending when it would redisplay, when it coalesces at all.
        let typeaheadWindow = 10_000
        var groupStart: Int?
        var groupKeys: [SimulatedKey] = []
        var groupDownlink = 0
        var groupJitter: UInt64 = 0
        var arrivals: [(readAt: Int, index: Int)] = []
        var readCursor = 0
        for (index, keystroke) in simulationCase.keystrokes.enumerated() {
            typedAt += keystroke.gap
            schedule(.keystroke(index), at: typedAt)
            readCursor = max(readCursor, typedAt + keystroke.uplink)
            arrivals.append((readCursor, index))
        }
        func flushGroup() {
            guard let start = groupStart, !groupKeys.isEmpty else { return }
            let reply = remote.readTogether(groupKeys)
            repliedAt = max(repliedAt, start + typeaheadWindow + groupDownlink)
            scheduleReply(reply, from: &repliedAt, jitterSeed: groupJitter)
            groupStart = nil
            groupKeys = []
        }
        for (index, keystroke) in simulationCase.keystrokes.enumerated() {
            guard simulationCase.coalescesTypeahead else { break }
            let arrival = arrivals[index].readAt
            if let start = groupStart, arrival > start + typeaheadWindow { flushGroup() }
            if groupStart == nil {
                groupStart = arrival
                groupDownlink = keystroke.downlink
                groupJitter = keystroke.jitterSeed
            }
            groupKeys.append(keystroke.key)
        }
        if simulationCase.coalescesTypeahead {
            flushGroup()
            return
        }
        for (index, keystroke) in simulationCase.keystrokes.enumerated() {
            readAt = max(readAt, arrivals[index].readAt)
            let reply = remote.read(keystroke.key, eraseForm: simulationCase.eraseForm)
            repliedAt = max(repliedAt, readAt + keystroke.downlink)
            scheduleReply(reply, from: &repliedAt, jitterSeed: keystroke.jitterSeed)
        }
    }

    /// Splits one reply into reads at random boundaries, starting at `time`.
    private mutating func scheduleReply(_ reply: [UInt8], from time: inout Int, jitterSeed: UInt64) {
        var random = SimulationRandom(seed: jitterSeed)
        var start = 0
        while start < reply.count {
            let length = Int.random(in: 1...(reply.count - start), using: &random)
            schedule(
                .read(
                    Array(reply[start..<(start + length)]),
                    drainDelay: Int.random(in: 0...4_000, using: &random),
                    renderDelay: Int.random(in: 0...8_000, using: &random)
                ),
                at: time
            )
            start += length
            time += Int.random(in: 0...3_000, using: &random)
        }
    }

    mutating func run() -> SimulationFailure? {
        scheduleInputs()
        while true {
            let next = queue.indices.min { lhs, rhs in
                (queue[lhs].time, queue[lhs].order) < (queue[rhs].time, queue[rhs].order)
            }
            if let deadline = expiryTask, next.map({ deadline < queue[$0].time }) ?? true {
                expiryTask = nil
                trace.append("\(deadline)µs expiry tick")
                if engine.tick(at: Self.instant(deadline)) { sync(at: deadline) }
                rescheduleExpiry(at: deadline)
                if let failure = check(at: deadline) { return failure }
                continue
            }
            guard let next else { return nil }
            let scheduled = queue.remove(at: next)
            handle(scheduled.event, at: scheduled.time)
            rescheduleExpiry(at: scheduled.time)
            if let failure = check(at: scheduled.time) { return failure }
        }
    }

    private mutating func handle(_ event: Event, at time: Int) {
        let now = Self.instant(time)
        switch event {
        case .keystroke(let index):
            let key = simulationCase.keystrokes[index].key
            _ = intended.read(key, eraseForm: simulationCase.eraseForm)
            let changed: Bool
            switch key {
            case .character(let byte):
                changed = engine.typed(printableASCII: byte, at: now)
            case .backspace:
                changed = engine.typedBackspace(at: now)
            }
            trace.append("\(time)µs type \(key)\(changed ? " (redraw)" : "")")
            if changed { sync(at: time) }

        case .read(let bytes, let drainDelay, let renderDelay):
            screen.apply(bytes)
            inbox.append((time, bytes))
            trace.append("\(time)µs read \(Self.describe(bytes)) cursor=\(screen.cursor)")
            if !isDrainScheduled {
                isDrainScheduled = true
                schedule(.drain, at: time + drainDelay)
            }
            if !isFrameScheduled {
                isFrameScheduled = true
                schedule(.frame, at: time + renderDelay)
            }

        case .drain:
            isDrainScheduled = false
            var changed = false
            for batch in inbox {
                screenSeenByEngine.apply(batch.bytes)
                changed = engine.observedOutput(batch.bytes, at: Self.instant(batch.time)) || changed
            }
            inbox.removeAll()
            trace.append("\(time)µs drain\(changed ? " (redraw)" : "")")
            if changed { sync(at: time) }

        case .frame:
            isFrameScheduled = false
            guard isTrackingFrames else { return }
            _ = engine.presentedFrame(at: now)
            trace.append("\(time)µs frame")
            sync(at: time)
        }
    }

    /// The host's `syncPredictionOverlay`: re-anchor on the live cursor.
    private mutating func sync(at time: Int) {
        engine.tick(at: Self.instant(time))
        let glyphs = engine.glyphs
        guard !glyphs.isEmpty else {
            overlay = []
            isTrackingFrames = false
            return
        }
        isTrackingFrames = true
        overlay = glyphs.map {
            DrawnGlyph(column: screen.cursor + $0.offset, character: $0.character, standing: $0.standing)
        }
        trace.append("    overlay \(Self.describe(overlay)) at cursor \(screen.cursor)")
        if overlay.contains(where: { $0.standing == .speculative }) { predictedEvents += 1 }
    }

    private mutating func rescheduleExpiry(at time: Int) {
        guard let deadline = engine.nextExpiry else {
            expiryTask = nil
            return
        }
        let micros = Int(deadline.components.seconds) * 1_000_000
            + Int(deadline.components.attoseconds / 1_000_000_000_000)
        // The host's timer fires after the deadline, never on it, and the
        // engine expires only what is strictly past it.
        expiryTask = max(time, micros) + 1
    }

    private func check(at time: Int) -> SimulationFailure? {
        // The engine against the output it has read: exact after every event.
        for glyph in engine.glyphs {
            let column = screenSeenByEngine.cursor + glyph.offset
            if let problem = misplacement(
                column: column,
                character: glyph.character,
                standing: glyph.standing,
                screen: screenSeenByEngine
            ) {
                return SimulationFailure(
                    message: "engine at \(time)µs: \(problem); glyphs \(engine.glyphs.map { "\($0.character)@\($0.offset)" }) cursor \(screenSeenByEngine.cursor)",
                    trace: trace
                )
            }
        }
        // The overlay once the host has caught up with the parser: every read
        // drained and the frame after it presented.
        guard !isDrainScheduled, !isFrameScheduled else { return nil }
        for glyph in overlay {
            if let problem = misplacement(
                column: glyph.column,
                character: glyph.character,
                standing: glyph.standing,
                screen: screen
            ) {
                return SimulationFailure(
                    message: "overlay at \(time)µs: \(problem); overlay \(Self.describe(overlay)) cursor \(screen.cursor)",
                    trace: trace
                )
            }
        }
        return nil
    }

    private func misplacement(
        column: Int,
        character: Character,
        standing: PredictedGlyph.Standing,
        screen: SimulatedScreen
    ) -> String? {
        let byte = character.asciiValue
        switch standing {
        case .speculative:
            // Where the remote will put it once every typed key is echoed.
            let row = intended.row
            let landing = column >= 0 && column < row.count ? row[column] : nil
            guard landing == byte else {
                return "speculative '\(character)' drawn at column \(column), which will hold \(landing.map { "'\(Character(UnicodeScalar($0)))'" } ?? "nothing")"
            }
        case .confirmed:
            guard screen.character(at: column) == byte else {
                return "confirmed '\(character)' drawn at column \(column), which holds \(screen.character(at: column).map { "'\(Character(UnicodeScalar($0)))'" } ?? "nothing")"
            }
        }
        return nil
    }

    private static func describe(_ bytes: [UInt8]) -> String {
        "\"" + bytes.map { byte -> String in
            switch byte {
            case 0x08: "\\b"
            case 0x07: "\\a"
            case 0x1B: "\\e"
            default: String(UnicodeScalar(byte))
            }
        }.joined() + "\""
    }

    private static func describe(_ overlay: [DrawnGlyph]) -> String {
        overlay.map { "\($0.character)@\($0.column)\($0.standing == .confirmed ? "✓" : "")" }
            .joined(separator: " ")
    }
}

enum SimulationCases {
    static let alphabet = Array("asdfjo".utf8)

    static func make(seed: UInt64) -> SimulationCase {
        var random = SimulationRandom(seed: seed)
        // Both sides of the 25 ms engage threshold.
        let roundTrip = [3_000, 12_000, 30_000, 50_000, 70_000, 120_000, 250_000]
            .randomElement(using: &random)!
        var keystrokes: [SimulatedKeystroke] = []

        func add(_ key: SimulatedKey, gap: Int) {
            let trip = roundTrip * Int.random(in: 60...140, using: &random) / 100
            let uplink = trip * Int.random(in: 30...70, using: &random) / 100
            keystrokes.append(SimulatedKeystroke(
                key: key,
                gap: gap,
                uplink: uplink,
                downlink: trip - uplink,
                jitterSeed: random.next()
            ))
        }

        let length = Int.random(in: 4...60, using: &random)
        while keystrokes.count < length {
            switch Int.random(in: 0..<10, using: &random) {
            case 0...3:
                for _ in 0..<Int.random(in: 1...8, using: &random) {
                    add(.character(alphabet.randomElement(using: &random)!),
                        gap: Int.random(in: 15_000...180_000, using: &random))
                }
            case 4...5:
                for _ in 0..<Int.random(in: 1...6, using: &random) {
                    add(.backspace, gap: Int.random(in: 30_000...160_000, using: &random))
                }
            case 6:
                // A held key: the initial delay, then autorepeat.
                let key: SimulatedKey = Bool.random(using: &random)
                    ? .backspace
                    : .character(alphabet.randomElement(using: &random)!)
                add(key, gap: Int.random(in: 20_000...200_000, using: &random))
                for _ in 0..<Int.random(in: 2...12, using: &random) {
                    add(key, gap: 33_000)
                }
            case 7:
                add(.character(alphabet.randomElement(using: &random)!),
                    gap: Int.random(in: 300_000...2_500_000, using: &random))
            default:
                // A typo corrected at typing speed.
                add(.character(alphabet.randomElement(using: &random)!),
                    gap: Int.random(in: 30_000...120_000, using: &random))
                add(.backspace, gap: Int.random(in: 40_000...140_000, using: &random))
            }
        }
        return SimulationCase(
            keystrokes: keystrokes,
            eraseForm: SimulatedEraseForm.allCases.randomElement(using: &random)!
        )
    }

    /// The dogfood report: a fast burst, then Backspace mashed or held at
    /// key-repeat speed, over a link slow enough to predict. Sometimes the
    /// Backspaces run past the burst into the prompt, where bash rings the
    /// bell, and sometimes they start after part of the burst was echoed.
    static func makeBurstThenDelete(seed: UInt64) -> SimulationCase {
        var random = SimulationRandom(seed: seed)
        let roundTrip = Int.random(in: 30_000...250_000, using: &random)
        var keystrokes: [SimulatedKeystroke] = []

        func add(_ key: SimulatedKey, gap: Int) {
            let trip = roundTrip * Int.random(in: 80...120, using: &random) / 100
            let uplink = trip * Int.random(in: 40...60, using: &random) / 100
            keystrokes.append(SimulatedKeystroke(
                key: key,
                gap: gap,
                uplink: uplink,
                downlink: trip - uplink,
                jitterSeed: random.next()
            ))
        }

        for _ in 0..<Int.random(in: 1...3, using: &random) {
            let burst = Int.random(in: 1...12, using: &random)
            for _ in 0..<burst {
                add(.character(alphabet.randomElement(using: &random)!),
                    gap: Int.random(in: 15_000...70_000, using: &random))
            }
            let pause = Bool.random(using: &random)
                ? Int.random(in: 20_000...60_000, using: &random)
                : Int.random(in: 100_000...600_000, using: &random)
            let deletes = max(1, burst + Int.random(in: -3...3, using: &random))
            for index in 0..<deletes {
                add(.backspace, gap: index == 0 ? pause : Int.random(in: 28_000...40_000, using: &random))
            }
            add(.character(alphabet.randomElement(using: &random)!),
                gap: Int.random(in: 50_000...900_000, using: &random))
        }
        return SimulationCase(
            keystrokes: keystrokes,
            eraseForm: Int.random(in: 0..<4, using: &random) == 0
                ? SimulatedEraseForm.allCases.randomElement(using: &random)!
                : .backspaceClearToEnd
        )
    }

    /// Runs the seeds and reports the first failure, shrunk, with the case
    /// as a literal to pin as a regression.
    static func firstFailure(
        seeds: ClosedRange<UInt64>,
        make: (UInt64) -> SimulationCase
    ) -> String? {
        for seed in seeds {
            let simulationCase = make(seed)
            var simulation = PredictionSimulation(simulationCase)
            guard simulation.run() != nil else { continue }
            let (minimal, failure) = shrink(simulationCase)
            return "seed \(seed)\n\(literal(minimal))\n\(failure)"
        }
        return nil
    }

    static func literal(_ simulationCase: SimulationCase) -> String {
        let keystrokes = simulationCase.keystrokes.map { keystroke in
            let key = switch keystroke.key {
            case .character(let byte): ".character(UInt8(ascii: \"\(Character(UnicodeScalar(byte)))\"))"
            case .backspace: ".backspace"
            }
            return "    SimulatedKeystroke(key: \(key), gap: \(keystroke.gap), uplink: \(keystroke.uplink), downlink: \(keystroke.downlink), jitterSeed: \(keystroke.jitterSeed)),"
        }
        return "SimulationCase(keystrokes: [\n\(keystrokes.joined(separator: "\n"))\n], eraseForm: .\(simulationCase.eraseForm))"
    }

    /// Deletes keystrokes while the case still fails, for a readable trace.
    static func shrink(_ failing: SimulationCase) -> (SimulationCase, SimulationFailure) {
        var current = failing
        var simulation = PredictionSimulation(current)
        var failure = simulation.run()!
        var progress = true
        while progress {
            progress = false
            var index = 0
            while index < current.keystrokes.count {
                var candidate = current
                let removed = candidate.keystrokes.remove(at: index)
                if index < candidate.keystrokes.count {
                    candidate.keystrokes[index].gap += removed.gap
                }
                var attempt = PredictionSimulation(candidate)
                if let smaller = attempt.run() {
                    current = candidate
                    failure = smaller
                    progress = true
                } else {
                    index += 1
                }
            }
        }
        return (current, failure)
    }
}

struct TerminalPredictionSimulationTests {
    @Test func everyDrawnGlyphLandsWhereItsCharacterWill() {
        if let failure = SimulationCases.firstFailure(seeds: 1...4_000, make: SimulationCases.make) {
            Issue.record(Comment(rawValue: failure))
        }
    }

    @Test func aBurstThenMashedBackspaceKeepsEveryGlyphOnItsCell() {
        if let failure = SimulationCases.firstFailure(
            seeds: 1...4_000,
            make: SimulationCases.makeBurstThenDelete
        ) {
            Issue.record(Comment(rawValue: failure))
        }
    }

    @Test func aRemoteThatCoalescesTypeaheadKeepsEveryGlyphOnItsCell() {
        for make in [SimulationCases.make, SimulationCases.makeBurstThenDelete] {
            if let failure = SimulationCases.firstFailure(seeds: 1...4_000, make: {
                var simulationCase = make($0)
                simulationCase.coalescesTypeahead = true
                return simulationCase
            }) {
                Issue.record(Comment(rawValue: failure))
            }
        }
    }

    @Test func theSimulationActuallyPredicts() {
        var predicting = 0
        for seed in UInt64(1)...200 {
            var simulation = PredictionSimulation(SimulationCases.makeBurstThenDelete(seed: seed))
            _ = simulation.run()
            if simulation.predictedEvents > 0 { predicting += 1 }
        }
        #expect(predicting > 150)
    }

    private func expectPasses(_ simulationCase: SimulationCase) {
        var simulation = PredictionSimulation(simulationCase)
        if let failure = simulation.run() {
            Issue.record(Comment(rawValue: failure.description))
        }
    }

    /// Minimal trace behind the dogfood report of a burst's own glyph drawn
    /// cells right of the cursor. "d" and "f" go out before any echo, so
    /// neither is drawn; "a" is. Ghostty parses the echo of "f" and renders a
    /// frame before the engine drains it, so the overlay re-anchors on the
    /// advanced cursor with the old offsets. Draining the echo of an undrawn
    /// keystroke changed nothing drawn, so nothing asked for a redraw, and
    /// "a" stayed one cell right per such echo until the next frame.
    @Test func anUndrawnEchoStillReanchorsTheOverlay() {
        expectPasses(SimulationCase(keystrokes: [
            SimulatedKeystroke(key: .character(UInt8(ascii: "d")), gap: 39435, uplink: 99559, downlink: 72095, jitterSeed: 9648886400068060533),
            SimulatedKeystroke(key: .character(UInt8(ascii: "f")), gap: 97648, uplink: 70486, downlink: 62507, jitterSeed: 15040563541741120241),
            SimulatedKeystroke(key: .character(UInt8(ascii: "a")), gap: 94418, uplink: 62630, downlink: 62631, jitterSeed: 13166747327335888811),
        ], eraseForm: .cursorLeftDeleteCharacter))
    }

    /// Backspace on an empty line withdraws. The engine then dropped every
    /// keystroke in flight, so the echo of the first "d" was matched to the
    /// second, arming a run one cell behind the remote, and "a" was drawn
    /// where the second "d" lands.
    @Test func echoesOfDroppedKeystrokesDoNotArmANewRun() {
        expectPasses(SimulationCase(keystrokes: [
            SimulatedKeystroke(key: .backspace, gap: 2307225, uplink: 181125, downlink: 81375, jitterSeed: 15060688257749113825),
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 93828, uplink: 90200, downlink: 129800, jitterSeed: 12550267593603473558),
            SimulatedKeystroke(key: .character(UInt8(ascii: "d")), gap: 173569, uplink: 106750, downlink: 68250, jitterSeed: 4262448622762034288),
            SimulatedKeystroke(key: .character(UInt8(ascii: "d")), gap: 109962, uplink: 112500, downlink: 112500, jitterSeed: 10403133260724467383),
            SimulatedKeystroke(key: .character(UInt8(ascii: "a")), gap: 125999, uplink: 98175, downlink: 94325, jitterSeed: 16371842306727156016),
        ], eraseForm: .cursorLeftDeleteCharacter))
    }

    /// The same misalignment from Backspace over echoed text followed by
    /// fast typing, over bash's `\b\e[K`.
    @Test func backspaceOverEchoedTextThenTypingStaysAligned() {
        expectPasses(SimulationCase(keystrokes: [
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 464991, uplink: 82596, downlink: 59812, jitterSeed: 12520115931017865071),
            SimulatedKeystroke(key: .backspace, gap: 518660, uplink: 54152, downlink: 52030, jitterSeed: 16642402136693730543),
            SimulatedKeystroke(key: .character(UInt8(ascii: "a")), gap: 91549, uplink: 59624, downlink: 79037, jitterSeed: 15997237259192702023),
            SimulatedKeystroke(key: .character(UInt8(ascii: "j")), gap: 117581, uplink: 61385, downlink: 84771, jitterSeed: 9661113692231963010),
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 73487, uplink: 56663, downlink: 44522, jitterSeed: 11641246956492036942),
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 88214, uplink: 56214, downlink: 68706, jitterSeed: 2456294479701936419),
            SimulatedKeystroke(key: .character(UInt8(ascii: "a")), gap: 103111, uplink: 64083, downlink: 78325, jitterSeed: 16277613484114632174),
        ], eraseForm: .backspaceClearToEnd))
    }

    /// Backspace over the echoed "f" withdraws, and a remote that coalesces
    /// typeahead sends nothing for "⌫f", whose net change is none. The echo
    /// of the second "f" arrived after the untracked window and was matched
    /// to the first, re-arming one cell behind the remote, so "d" was drawn
    /// right of where it lands and stayed there until it expired.
    @Test func aKeyTypedWhileEchoesAreUntrackedDoesNotArmARun() {
        var simulationCase = SimulationCase(keystrokes: [
            SimulatedKeystroke(key: .character(UInt8(ascii: "f")), gap: 245673, uplink: 30870, downlink: 42630, jitterSeed: 2300655970432197423),
            SimulatedKeystroke(key: .backspace, gap: 139067, uplink: 47124, downlink: 24276, jitterSeed: 13452741299809415594),
            SimulatedKeystroke(key: .character(UInt8(ascii: "f")), gap: 17750, uplink: 20384, downlink: 43316, jitterSeed: 14211843459011219229),
            SimulatedKeystroke(key: .character(UInt8(ascii: "f")), gap: 116774, uplink: 52542, downlink: 44758, jitterSeed: 5850673420601723284),
            SimulatedKeystroke(key: .character(UInt8(ascii: "d")), gap: 909700, uplink: 28980, downlink: 13020, jitterSeed: 16764482466942078549),
        ], eraseForm: .backspaceClearToEnd)
        simulationCase.coalescesTypeahead = true
        expectPasses(simulationCase)
    }

    /// The link measures fast mid-run, so "j" is typed undrawn behind a held
    /// "s". Removing "j" at its echo dropped a cell the cursor had passed,
    /// and the held "s" slid onto the cell after it.
    @Test func aHeldGlyphKeepsItsCellWhenAnUndrawnEchoFollows() {
        expectPasses(SimulationCase(keystrokes: [
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 57475, uplink: 13398, downlink: 9702, jitterSeed: 13857595088430517430),
            SimulatedKeystroke(key: .character(UInt8(ascii: "j")), gap: 666034, uplink: 16638, downlink: 18762, jitterSeed: 8691134027776269367),
            SimulatedKeystroke(key: .character(UInt8(ascii: "a")), gap: 329636, uplink: 19323, downlink: 14577, jitterSeed: 4221019582071791041),
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 6539567, uplink: 9792, downlink: 10608, jitterSeed: 1270321287885520511),
            SimulatedKeystroke(key: .character(UInt8(ascii: "s")), gap: 18044, uplink: 8118, downlink: 11682, jitterSeed: 17235541091325165141),
            SimulatedKeystroke(key: .character(UInt8(ascii: "j")), gap: 60004, uplink: 9936, downlink: 11664, jitterSeed: 5103199448813725791),
        ], eraseForm: .cursorLeftDeleteCharacter))
    }
}
