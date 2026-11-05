import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The link-hint controller against a small reference model (after four review rounds of #32537 each found one ordering
/// bug). Seeded random sequences of events: typed keys (a hint letter, a letter that is no label's, a key that is no hint
/// key, Escape, Backspace, the chord that starts link hints), a click, the keyboard leaving the page and coming back,
/// the page's answers (a text field has the keyboard, no text field, no answer; its targets, none, or a failed call; its
/// label scripts) and the answer's bound. After every event: no typed key is lost, none reaches the app twice, a key the
/// session took (a hint letter) never reaches the page, keys reach the app in the order typed, and the controller's one
/// session is the model's. `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay or widen a run.
@MainActor @Suite(.serialized, .closesItsWindows) struct LinkHintControllerFuzzTests {
    @Test func randomEventsKeepEveryKeyOnceInOrderAndHintLettersOffThePage() async throws {
        let fuzz = FuzzSeed(default: 0x11_4B_32_537)
        var rng = Rng(state: fuzz.seed)
        let rig = try Rig()
        defer { rig.shell.closeAfterTest() }
        for sequence in 0..<fuzz.iterations(3_000) {
            rig.reset()
            var model = Model(), log: [String] = [], typed = 0, failure: String?
            for step in 0..<25 {
                let event = step == 0 ? Event.type(.start) : Self.event(&rng, model)
                log.append("\(event)")
                await rig.apply(event, to: &model, typed: &typed)
                failure = Self.check(model, rig)
                if failure != nil { break }
            }
            if failure == nil {
                log.append("end")
                await rig.finish(&model)
                failure = Self.check(model, rig) ?? Self.lossless(model, typed: typed)
            }
            if let failure {
                Issue.record("""
                \(fuzz), sequence \(sequence): \(failure)
                events: \(log.joined(separator: ", "))
                the app got: \(rig.reached)
                the model:   \(model.reached)
                """)
                return
            }
        }
    }

    // MARK: Events

    nonisolated enum Typed: Equatable, CustomStringConvertible {
        case letter(String), backspace, escape, other, start

        var description: String {
            switch self {
            case .letter(let letter): letter
            case .backspace: "<bs>"
            case .escape: "<esc>"
            case .other: "<space>"
            case .start: "<ctrl-f>"
            }
        }
    }

    nonisolated enum Event: CustomStringConvertible {
        case type(Typed), click, leave, back, field, noField, noAnswer, targets(Int), failedTargets, scripts, timeout

        var description: String {
            switch self {
            case .type(let key): "\(key)"
            case .click: "click"
            case .leave: "focus-lost"
            case .back: "focus-back"
            case .field: "answer:field"
            case .noField: "answer:no-field"
            case .noAnswer: "answer:none"
            case .targets(let count): "targets:\(count)"
            case .failedTargets: "targets:failed"
            case .scripts: "scripts"
            case .timeout: "bound"
            }
        }
    }

    nonisolated struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }

        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    /// A random event; the page answers only what the model's session asked.
    private static func event(_ rng: inout Rng, _ model: Model) -> Event {
        let alphabet = LinkHintSession.alphabet
        switch rng.below(100) {
        case ..<24: return .type(.letter(alphabet[rng.below(alphabet.count)]))
        case ..<27: return .type(.letter("z"))
        case ..<34: return .type(.other)
        case ..<39: return .type(.escape)
        case ..<42: return .type(.backspace)
        case ..<50: return .type(.start)
        case ..<54: return .click
        case ..<57: return .leave
        case ..<62: return .back
        case ..<82:
            let roll = rng.below(20)
            switch model.phase {
            case .asking: return roll < 5 ? .field : roll < 17 ? .noField : .noAnswer
            case .noField: return roll < 14 ? .targets(1 + rng.below(40)) : roll < 18 ? .targets(0) : .failedTargets
            case .idle, .shown: return .scripts
            }
        case ..<94: return .scripts
        default: return .timeout
        }
    }

    // MARK: The model

    /// One key event that reached the app's dispatch past link hints: a key-down, or its key-up.
    nonisolated struct Reach: Equatable, CustomStringConvertible {
        var id: Int
        var up: Bool
        var description: String { up ? "^\(id)" : "\(id)" }
    }

    /// What the controller must do, written from its rules (not its code). A session asks the page whether a text field
    /// has the keyboard (`asking`: every key waits, in order); with a field, or no answer, every waiting key is the
    /// page's. With no field the waiting keys run through the session as typed and later keys are handled live
    /// (`noField`) until the labels show (`shown`). A hint letter, Backspace or Escape is the session's; any other key
    /// ends it and goes on; a complete label picks and ends it; a click before the labels ends it; a key when the page no
    /// longer has the keyboard ends it and goes on. Keys a session ends with go on before any key after them.
    nonisolated struct Model {
        nonisolated enum Phase: Equatable { case idle, asking, noField, shown }

        var phase = Phase.idle
        var focused = true
        var held: [(id: Int, key: Typed)] = []
        var typed = ""
        var labels: [String] = []
        var reached: [Reach] = []
        /// Key-downs the session took (hint letters, Backspace, Escape): never the page's.
        var taken: Set<Int> = []
        var noLinks = 0

        /// A key-down reaches the app's dispatch: the chord starts link hints when the page has the keyboard.
        private mutating func dispatch(_ id: Int, _ key: Typed) {
            reached.append(Reach(id: id, up: false))
            if key == .start, focused { (phase, held, typed, labels) = (.asking, [], "", []) }
        }

        private mutating func up(_ id: Int) { reached.append(Reach(id: id, up: true)) }

        /// The session ends; before its page answered, the keys typed meanwhile go on, in order.
        mutating func end() {
            let release = phase == .asking ? held : []
            (phase, held) = (.idle, [])
            for key in release { dispatch(key.id, key.key); up(key.id) }
        }

        mutating func type(_ id: Int, _ key: Typed) {
            switch phase {
            case .idle:
                dispatch(id, key)
                up(id)
            case .asking where focused:
                held.append((id, key)) // its key-up waits behind it
            case .asking, .noField, .shown:
                guard focused else { end(); dispatch(id, key); return up(id) }
                switch key {
                case .escape: taken.insert(id); end()
                case .other, .start: end(); dispatch(id, key)
                case .letter(let letter): taken.insert(id); press(letter)
                case .backspace: taken.insert(id); press(nil)
                }
                up(id)
            }
        }

        private mutating func press(_ letter: String?) {
            if let letter {
                let next = typed + letter
                if phase == .noField || labels.contains(where: { $0.hasPrefix(next) }) { typed = next }
            } else if !typed.isEmpty {
                typed.removeLast()
            }
            if phase == .shown, labels.contains(typed) { phase = .idle } // picked
        }

        mutating func click() { if phase == .asking || phase == .noField { end() } }

        mutating func timeout() { if phase == .asking { end() } }

        /// The page said no text field has the keyboard.
        mutating func noField() {
            let keys = held
            (held, typed) = ([], "")
            var ended = false, page: [(id: Int, key: Typed)] = []
            for key in keys {
                guard !ended else { page.append(key); continue }
                switch key.key {
                case .escape: taken.insert(key.id); ended = true
                case .other, .start: ended = true; page.append(key)
                case .letter(let letter): taken.insert(key.id); typed += letter
                case .backspace: taken.insert(key.id); if !typed.isEmpty { typed.removeLast() }
                }
            }
            phase = ended ? .idle : .noField
            for key in page { dispatch(key.id, key.key); up(key.id) }
        }

        /// The page's targets came (0: none, or the call failed).
        mutating func targets(_ count: Int) {
            labels = LinkHintSession.labels(count: count)
            guard !labels.isEmpty else { noLinks += 1; phase = .idle; return }
            while !typed.isEmpty, !labels.contains(where: { $0.hasPrefix(typed) }) { typed.removeLast() }
            phase = labels.contains(typed) ? .idle : .shown
        }
    }

    // MARK: Checks

    /// The invariants after one event: each against the app's dispatch, then the model's exact sequence and session.
    private static func check(_ model: Model, _ rig: Rig) -> String? {
        // A key-up of a key the session took reaches the app without its key-down; any other comes after its key-down.
        let allDowns = Set(rig.reached.filter { !$0.up }.map(\.id))
        var downs = Set<Int>(), ups = Set<Int>(), last = 0
        for reach in rig.reached {
            if reach.up {
                guard ups.insert(reach.id).inserted else { return "the key-up of key \(reach.id) reached the app twice" }
                if allDowns.contains(reach.id), !downs.contains(reach.id) { return "the key-up of key \(reach.id) reached the app before its key-down" }
                continue
            }
            guard downs.insert(reach.id).inserted else { return "key \(reach.id) (\(rig.key(reach.id))) reached the app twice" }
            guard reach.id > last else { return "key \(reach.id) (\(rig.key(reach.id))) reached the app after key \(last), typed after it" }
            last = reach.id
            if model.taken.contains(reach.id) { return "key \(reach.id) (\(rig.key(reach.id))) is the session's and reached the page" }
        }
        let expected = Set(model.reached.filter { !$0.up }.map(\.id))
        if let lost = expected.subtracting(downs).min() { return "key \(lost) (\(rig.key(lost))) was lost or is still held" }
        guard rig.reached == model.reached else { return "the app got other key events than the model" }
        guard rig.controller.isActive == (model.phase != .idle) else {
            return model.phase == .idle ? "a session is live that ended" : "the session (\(model.phase)) is gone"
        }
        guard rig.noLinks == model.noLinks else { return "'no links' showed \(rig.noLinks) times, the model \(model.noLinks)" }
        return nil
    }

    /// At the end of a sequence every typed key is the session's or reached the app: the model itself loses none.
    private static func lossless(_ model: Model, typed: Int) -> String? {
        let reached = Set(model.reached.filter { !$0.up }.map(\.id))
        return (1...max(typed, 1)).first { !model.taken.contains($0) && !reached.contains($0) }.map { "the model lost key \($0)" }
    }

    // MARK: The rig

    /// Answers the test gives when it chooses. A waiter whose task is cancelled gets nil at once, as a page call ends
    /// when its session does.
    @MainActor private final class Answers<Value: Sendable> {
        private var waiters: [Int: CheckedContinuation<Value?, Never>] = [:]
        private var cancelled: Set<Int> = []
        private var asked = 0
        var isAsked: Bool { !waiters.isEmpty }
        nonisolated deinit {}

        func next() async -> Value? {
            asked += 1
            let id = asked
            return await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    if cancelled.remove(id) != nil { waiter.resume(returning: nil) } else { waiters[id] = waiter }
                }
            } onCancel: {
                MainActor.assumeIsolated { self.cancel(id) } // the controller cancels its tasks on the main actor
            }
        }

        private func cancel(_ id: Int) {
            if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: nil) } else { cancelled.insert(id) }
        }

        func give(_ value: Value?) {
            let all = waiters.sorted { $0.key < $1.key }.map(\.value)
            waiters = [:]
            for waiter in all { waiter.resume(returning: value) }
        }
    }

    /// The controller on a tab whose page answers when the test says, inside the app's key dispatch as `KeyRouter` and
    /// `CmuxApplication` run it: what reaches the app past link hints, and the chord that starts link hints again.
    @MainActor private final class Rig {
        let controller = LinkHintController()
        let focus = Answers<Bool>()
        let targets = Answers<[LinkHintTarget]>()
        let scripts = Answers<Bool>()
        let shell = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let tab: CEFTab
        var focused = true
        private(set) var reached: [Reach] = []
        private(set) var noLinks = 0
        private var reaches: [ObjectIdentifier: Reach] = [:]
        private var events: [NSEvent] = []
        private var keys: [Int: Typed] = [:]

        static var runtimes: [CEFRuntime] = []

        init() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "link-hints-fuzz-\(UUID().uuidString)", directoryHint: .isDirectory)
            let runtime = CEFRuntime(shim: try Self.library(), storage: CEFProfileStorage(root: root))
            Self.runtimes.append(runtime)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            controller.focusAnswer = { [focus] _ in await focus.next() }
            controller.targetsAnswer = { [targets] _ in await targets.next() }
            controller.script = { [scripts] _, source in
                guard await scripts.next() != nil else { return nil }
                return .bool(source != LinkHintSession.removeScript) // the labels draw and narrow; a pick clicks nothing
            }
            controller.send = { [weak self] given in self?.dispatch(given) }
            controller.answerBound = .seconds(3_600) // the test plays the bound itself
        }

        func key(_ id: Int) -> String { keys[id].map { "\($0)" } ?? "?" }

        func reset() {
            (reached, noLinks, reaches, events, keys, focused) = ([], 0, [:], [], [:], true)
        }

        func apply(_ event: Event, to model: inout Model, typed: inout Int) async {
            switch event {
            case .type(let key):
                typed += 1
                model.type(typed, key)
                type(typed, key)
            case .click:
                model.click()
                _ = controller.inputWillDispatch(Self.mouseDown(in: shell))
            case .leave:
                model.focused = false
                focused = false
            case .back:
                model.focused = true
                focused = true
            case .field: model.end(); focus.give(true)
            case .noField: model.noField(); focus.give(false)
            case .noAnswer: model.end(); focus.give(nil)
            case .targets(let count): model.targets(count); targets.give(Self.labelTargets(count))
            case .failedTargets: model.targets(0); targets.give(nil)
            case .scripts: scripts.give(true)
            case .timeout: model.timeout(); controller.answerTimedOut()
            }
            await settle(model.phase)
        }

        /// The keyboard leaves the page and the session ends; the page's scripts answer.
        func finish(_ model: inout Model) async {
            model.focused = false
            focused = false
            model.end()
            controller.cancel()
            scripts.give(true)
            await settle(model.phase)
        }

        /// Lets the controller's page calls run, until the session the model has asked the page what it asks.
        private func settle(_ phase: Model.Phase) async {
            for _ in 0..<12 { await Task.yield() }
            let waits = { (phase == .asking && !self.focus.isAsked) || (phase == .noField && !self.targets.isAsked) }
            for _ in 0..<500 where waits() { await Task.yield() }
        }

        private func start() {
            controller.start(.follow, tab: tab, window: shell, isFocused: { [weak self] in self?.focused ?? false },
                             openInSplit: { _ in }, noLinks: { [weak self] in self?.noLinks += 1 })
        }

        /// A key typed into the page: its key-down, then its key-up.
        private func type(_ id: Int, _ key: Typed) {
            let pressed = Self.event(key, .keyDown, id: id, window: shell)
            let released = Self.event(key, .keyUp, id: id, window: shell)
            reaches[ObjectIdentifier(pressed)] = Reach(id: id, up: false)
            reaches[ObjectIdentifier(released)] = Reach(id: id, up: true)
            events += [pressed, released]
            keys[id] = key
            down(pressed)
            up(released)
        }

        /// A key-down through the app's dispatch: link hints see it first while a session runs (``KeyRouter``).
        private func down(_ event: NSEvent) {
            controller.noteKeyDown(event, in: shell)
            if controller.isActive, controller.interceptKeyDown(event, in: shell) { return }
            reach(event)
        }

        /// A key-up through the app's dispatch: link hints may hold it behind its key-down (``CmuxApplication``).
        private func up(_ event: NSEvent) {
            if controller.inputWillDispatch(event) { return }
            reach(event)
        }

        /// Keys link hints gave back, each through the app's dispatch again (``LinkHintController/send``).
        private func dispatch(_ given: [NSEvent]) {
            for event in given {
                if event.type == .keyUp { up(event) } else { down(event) }
            }
        }

        /// A key event past link hints; the chord runs the link-hints action when the page has the keyboard.
        private func reach(_ event: NSEvent) {
            guard let reach = reaches[ObjectIdentifier(event)] else {
                Issue.record("a key event the test never typed reached the app")
                return
            }
            reached.append(reach)
            if !reach.up, keys[reach.id] == .start, focused { start() }
        }

        private static func event(_ key: Typed, _ type: NSEvent.EventType, id: Int, window: NSWindow) -> NSEvent {
            let code = UInt16(200 + id)
            let (characters, plain, keyCode, flags): (String, String, UInt16, NSEvent.ModifierFlags) = switch key {
            case .letter(let letter): (letter, letter, code, [])
            case .other: (" ", " ", code, [])
            case .start: ("\u{6}", "f", code, [.control])
            case .escape: ("\u{1b}", "\u{1b}", 53, [])
            case .backspace: ("\u{7f}", "\u{7f}", 51, [])
            }
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: TimeInterval(id), windowNumber: window.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: keyCode)!
        }

        private static func mouseDown(in window: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        private static func labelTargets(_ count: Int) -> [LinkHintTarget] {
            (0..<count).map { LinkHintTarget(x: Double($0), y: 1, left: Double($0), top: 0) }
        }

        private static func library() throws -> CEFShimLibrary {
            let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
            let nothing: @convention(c) () -> Int = { 0 }
            return try CEFShimLibrary.resolving { name in
                name == "cmux_shim_create_window" ? unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self) : unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
