import Testing
@testable import CmuxTerminalPrediction

// A second harness, aimed at what the user sees rather than where each glyph
// sits. It plays keystrokes through a bash-readline-shaped remote over a link
// with per-key latency, presents a frame every 16.7 ms, and after every event
// composes the visible row: ghostty's grid with the overlay painted on top.
//
// The property it checks is the one a user notices: a character they deleted,
// and saw disappear, must not come back.

enum RigKey: Equatable, CustomStringConvertible {
    case character(UInt8)
    case backspace
    /// Ctrl-U, readline's unix-line-discard.
    case killLine
    /// Ctrl-W, readline's unix-word-rubout.
    case killWord
    /// A bracketed paste; its echo is untracked.
    case paste([UInt8])

    var description: String {
        switch self {
        case .character(let byte): String(UnicodeScalar(byte))
        case .backspace: "⌫"
        case .killLine: "^U"
        case .killWord: "^W"
        case .paste(let bytes): "paste(\(String(decoding: bytes, as: UTF8.self)))"
        }
    }

    static func text(_ string: String) -> [RigKey] {
        string.utf8.map { .character($0) }
    }
}

struct RigKeystroke {
    var key: RigKey
    /// Absolute time the key is typed, in microseconds.
    var at: Int
    var uplink: Int
    var downlink: Int
}

/// The remote line: readline with `\b\e[K` erases, as bash does under
/// TERM=xterm-ghostty.
struct RigLineEditor {
    var line: [UInt8] = []

    mutating func read(_ key: RigKey) -> [UInt8] {
        switch key {
        case .character(let byte):
            line.append(byte)
            return [byte]
        case .backspace:
            guard !line.isEmpty else { return [0x07] }
            line.removeLast()
            return [0x08, 0x1B, 0x5B, 0x4B]
        case .killLine:
            let count = line.count
            line.removeAll()
            return count == 0 ? [] : [UInt8](repeating: 0x08, count: count) + [0x1B, 0x5B, 0x4B]
        case .killWord:
            var removed = 0
            while let last = line.last, last == 0x20 { line.removeLast(); removed += 1 }
            while let last = line.last, last != 0x20 { line.removeLast(); removed += 1 }
            return removed == 0 ? [] : [UInt8](repeating: 0x08, count: removed) + [0x1B, 0x5B, 0x4B]
        case .paste(let bytes):
            line += bytes
            return bytes
        }
    }
}

struct RigFinding: CustomStringConvertible {
    var time: Int
    var column: Int
    var character: UInt8
    var visible: String
    var typed: String
    var description: String {
        "\(time / 1000) ms: column \(column) shows '\(Character(UnicodeScalar(character)))' again after it was deleted and hidden; visible \"\(visible)\", typed \"\(typed)\""
    }
}

struct PredictionBreakRig {
    private enum Event {
        case key(Int)
        /// The tee's copy reaches the engine (the main-actor drain).
        case output([UInt8])
        /// Ghostty's parser applies the same bytes to the grid.
        case parse([UInt8])
        case frame
    }

    /// How long after the remote reply arrives Ghostty spends applying a read.
    /// Ghostty PR #242 moved the tee after the parser, so both events share
    /// the parser's completion time and the grid always receives the bytes
    /// before the host can drain them.
    var parseLagMicros = 0
    /// Characters drawn over cells that hold, or will hold, something else.
    private(set) var wrongText: [String] = []
    /// Microseconds during which a typed character the grid already showed
    /// was blank on screen.
    private(set) var blankedMicros = 0
    private var blankedNow = false
    /// A typed character that was on screen went blank before it was deleted.
    private(set) var blankings: [String] = []

    var engine: TerminalPredictionEngine
    private(set) var screen = SimulatedScreen()
    private var remote = RigLineEditor()
    private var typed: [UInt8] = []
    private var events: [(time: Int, order: Int, event: Event)] = []
    private var order = 0
    private let keystrokes: [RigKeystroke]
    private let frameInterval = 16_667
    /// Columns the user deleted and then saw blank.
    private var hiddenAfterDelete: Set<Int> = []
    private(set) var resurrections: [RigFinding] = []
    /// Microseconds during which some deleted-and-hidden column showed text.
    private(set) var resurrectedMicros = 0
    private var lastVisibleCheck = 0
    private var resurrectedNow = false
    private var lastVisible: [UInt8] = []
    private(set) var trace: [String] = []
    private(set) var everDrewSpeculative = false

    init(
        keystrokes: [RigKeystroke],
        configuration: PredictionConfiguration = .default
    ) {
        self.keystrokes = keystrokes
        engine = TerminalPredictionEngine(
            configuration: configuration,
            isEnabled: true,
            isRemoteSurface: true
        )
    }

    private mutating func schedule(_ event: Event, at time: Int) {
        events.append((time, order, event))
        order += 1
    }

    static var promptWidth: Int { SimulatedLineEditor.prompt.count }

    /// What the user sees: the grid with the overlay painted over it.
    /// The last frame ghostty presented, and the overlay as the host last
    /// anchored it. Neither follows the grid between their own updates.
    private var presentedRow: [UInt8] = SimulatedLineEditor.prompt
    private var overlay: [(column: Int, byte: UInt8)] = []
    private var isTrackingFrames = false

    func visibleRow() -> [UInt8] {
        var row = presentedRow
        for (column, byte) in overlay where column >= 0 {
            while row.count <= column { row.append(0x20) }
            row[column] = byte
        }
        return row
    }

    /// `syncPredictionOverlay`: re-anchor on the cursor ghostty has parsed.
    private mutating func sync() {
        let glyphs = engine.glyphs
        overlay = glyphs.map { (screen.cursor + $0.offset, $0.character.asciiValue ?? 0x3F) }
        isTrackingFrames = !glyphs.isEmpty
    }

    private mutating func applyTyped(_ key: RigKey) {
        switch key {
        case .character(let byte): typed.append(byte)
        case .backspace: if !typed.isEmpty { typed.removeLast() }
        case .killLine: typed.removeAll()
        case .killWord:
            while let last = typed.last, last == 0x20 { typed.removeLast() }
            while let last = typed.last, last != 0x20 { typed.removeLast() }
        case .paste(let bytes): typed += bytes
        }
    }

    private mutating func check(at time: Int) {
        let visible = visibleRow()
        let typedEnd = Self.promptWidth + typed.count
        if resurrectedNow { resurrectedMicros += time - lastVisibleCheck }
        if blankedNow { blankedMicros += time - lastVisibleCheck }
        blankedNow = false
        let prompt = SimulatedLineEditor.prompt
        for column in 0..<min(prompt.count, visible.count) where visible[column] != prompt[column] {
            if wrongText.count < 20 {
                wrongText.append("\(time / 1000) ms: '\(Character(UnicodeScalar(visible[column])))' drawn over prompt column \(column) ('\(Character(UnicodeScalar(prompt[column])))')")
            }
        }
        for (index, expected) in typed.enumerated() {
            let column = prompt.count + index
            let shown = column < visible.count ? visible[column] : 0x20
            let wasShown = column < lastVisible.count && lastVisible[column] == expected
            if shown != expected && shown != 0x20 && wrongText.count < 20 {
                wrongText.append("\(time / 1000) ms: '\(Character(UnicodeScalar(shown)))' drawn at column \(column), typed '\(Character(UnicodeScalar(expected)))'")
            }
            if shown == 0x20 && wasShown && expected != 0x20 {
                blankedNow = true
                if blankings.count < 20 {
                    blankings.append("\(time / 1000) ms: typed '\(Character(UnicodeScalar(expected)))' at column \(column) went blank")
                }
            }
        }
        lastVisibleCheck = time
        resurrectedNow = false
        hiddenAfterDelete = hiddenAfterDelete.filter { $0 >= typedEnd }
        let width = max(visible.count, lastVisible.count, (hiddenAfterDelete.max() ?? 0) + 1)
        for column in typedEnd..<max(typedEnd, width) {
            let shown = column < visible.count ? visible[column] : 0x20
            let before = column < lastVisible.count ? lastVisible[column] : 0x20
            if shown == 0x20 {
                if before != 0x20 { hiddenAfterDelete.insert(column) }
            } else if hiddenAfterDelete.contains(column) {
                resurrectedNow = true
                if resurrections.count < 20 {
                    resurrections.append(RigFinding(
                        time: time,
                        column: column,
                        character: shown,
                        visible: String(decoding: visible.dropFirst(Self.promptWidth), as: UTF8.self),
                        typed: String(decoding: typed, as: UTF8.self)
                    ))
                }
            }
        }
        lastVisible = visible
        if engine.glyphs.contains(where: { $0.standing == .speculative }) { everDrewSpeculative = true }
    }

    mutating func run() {
        var readAt = 0
        var repliedAt = 0
        var remoteModel = RigLineEditor()
        for (index, keystroke) in keystrokes.enumerated() {
            schedule(.key(index), at: keystroke.at)
            readAt = max(readAt, keystroke.at + keystroke.uplink)
            let reply = remoteModel.read(keystroke.key)
            repliedAt = max(repliedAt, readAt + keystroke.downlink)
            if !reply.isEmpty {
                let parserFinishedAt = repliedAt + parseLagMicros
                schedule(.parse(reply), at: parserFinishedAt)
                schedule(.output(reply), at: parserFinishedAt)
            }
        }
        remote = remoteModel
        let end = (events.map(\.time).max() ?? 0) + 2_000_000
        var frameTime = frameInterval
        while frameTime < end {
            schedule(.frame, at: frameTime)
            frameTime += frameInterval
        }
        events.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        for (time, _, event) in events {
            let now = PredictionInstant.microseconds(time)
            switch event {
            case .key(let index):
                let key = keystrokes[index].key
                applyTyped(key)
                let changed: Bool
                switch key {
                case .character(let byte): changed = engine.typed(printableASCII: byte, at: now)
                case .backspace: changed = engine.typedBackspace(at: now)
                case .killLine, .killWord: changed = engine.typedLineErase(at: now)
                case .paste: changed = engine.sentUntrackedInput(at: now)
                }
                if changed { sync() }
                trace.append("\(time / 1000)ms type \(key) -> overlay \(engine.glyphs.map { "\($0.character)@\($0.offset)" })")
            case .parse(let bytes):
                screen.apply(bytes)
                trace.append("\(time / 1000)ms parse \(bytes.count)B cursor \(screen.cursor)")
            case .output(let bytes):
                if engine.observedOutput(bytes, at: now), !engine.holdsLayoutUntilFrame { sync() }
                trace.append("\(time / 1000)ms echo \(bytes.count)B -> overlay \(engine.glyphs.map { "\($0.character)@\($0.offset)" })")
            case .frame:
                presentedRow = screen.row
                let expired = engine.tick(at: now)
                if isTrackingFrames {
                    engine.presentedFrame(at: now)
                    sync()
                } else if expired {
                    sync()
                }
            }
            check(at: time)
        }
    }
}

/// Builds keystroke lists with a fixed or jittered round trip.
struct RigScript {
    var keystrokes: [RigKeystroke] = []
    var clock = 0
    var roundTrip: Int
    var jitter: Int = 0
    var random = SimulationRandom(seed: 1)

    init(roundTripMilliseconds: Int, jitterMilliseconds: Int = 0, seed: UInt64 = 1) {
        roundTrip = roundTripMilliseconds * 1000
        jitter = jitterMilliseconds * 1000
        random = SimulationRandom(seed: seed)
    }

    mutating func wait(_ milliseconds: Int) { clock += milliseconds * 1000 }

    mutating func press(_ key: RigKey, gapMilliseconds: Int = 30) {
        clock += gapMilliseconds * 1000
        let trip = roundTrip + (jitter > 0 ? Int.random(in: -jitter...jitter, using: &random) : 0)
        let uplink = max(1, trip / 2)
        keystrokes.append(RigKeystroke(key: key, at: clock, uplink: uplink, downlink: max(1, trip - uplink)))
    }

    mutating func type(_ text: String, gapMilliseconds: Int = 30) {
        for key in RigKey.text(text) { press(key, gapMilliseconds: gapMilliseconds) }
    }

    mutating func hold(_ key: RigKey, count: Int, initialDelayMilliseconds: Int = 0, repeatMilliseconds: Int = 33) {
        for index in 0..<count {
            press(key, gapMilliseconds: index == 0 ? initialDelayMilliseconds : repeatMilliseconds)
        }
    }

    /// Two echoed keystrokes so the run is armed, then a pause. (One is not
    /// enough: a tty in cooked mode echoes the first key typed ahead of a
    /// password prompt.)
    mutating func arm() {
        type("l", gapMilliseconds: 10)
        wait(1_000)
        type("s", gapMilliseconds: 10)
        wait(1_000)
    }
}
