public import CmuxNextControl
public import CmuxNextSettings
import AppKit
import CmuxNextPages
import CmuxNextWakeups
import Foundation

/// `agent.chat.drive` on the app control socket (every build, Release and Nightly too): drives one
/// agent chat page, named by tab id, the way a person's pointer would and reads what it drew. It
/// holds a real, engine-level hover on one element (`target`), sends `wheel.ticks` wheel ticks of
/// `wheel.delta` CSS px to the transcript under that held pointer, lets the page type `type.text`
/// into its composer if asked, and returns the page's per-frame report
/// (`window.cmuxAcpmuxBridge.drive`, webviews).
///
/// It never moves the system pointer, never focuses, raises or orders a window, never gives the
/// chat the keyboard, never shows or thaws the tab and runs no script of the caller's: the page
/// scripts are fixed and the caller's values reach them only as arguments. Input goes to the page's
/// own engine (``AgentChatDriveInput``). The person goes first: a chat the person's pointer is over,
/// or one they typed or clicked in within ``personQuietSeconds``, is refused, and a run stops
/// injecting (`interrupted: "person"`) the moment they come back to it. The hover is given back
/// on every path: the run's end, an error, a cancelled call, and a main-queue deadline at
/// `seconds` + 2 s that does not depend on the run.
public struct AgentChatDriveControl: Sendable {
    public nonisolated static let method = "agent.chat.drive"
    public nonisolated static let maxSeconds = 30
    public nonisolated static let defaultSeconds = 10
    /// How long after the person's own key or click in the chat it counts as theirs.
    nonisolated static let personQuietSeconds: TimeInterval = 2

    public typealias ChatPage = AgentChatPerfControl.ChatPage

    /// Looks the (normalized) tab id up in the App's tabs.
    let find: @MainActor @Sendable (String) -> ChatPage

    public init(find: @escaping @MainActor @Sendable (String) -> ChatPage) {
        self.find = find
    }

    /// The App's control service registers this (`AppControl`).
    public func controlMethod() -> ControlMethod {
        let find = find
        return .async(Self.method) { call in try await Self.run(call.params, find: find) }
            .withDeadline(.fixed(.seconds(Self.maxSeconds + 15)))
            .withLimit { request, _ in .seconds(((try? Params(request.params))?.seconds ?? Self.maxSeconds) + 15) }
    }

    /// The call's params, checked; anything else is refused (`invalid_params`).
    public nonisolated struct Params: Sendable, Equatable {
        /// The element to hover: at most one of these.
        public nonisolated enum Target: Sendable, Equatable {
            /// The element with this `data-testid` (letters, digits, `-` and `_`, 1 to 80).
            case testID(String)
            /// The nth image the person sent (from 1).
            case sentImage(Int)
            /// The nth tool screenshot (from 1).
            case toolScreenshot(Int)
        }

        public nonisolated struct Wheel: Sendable, Equatable {
            /// 0 to 200.
            public var ticks: Int
            /// CSS px per tick, the page's `wheel` `deltaY` sign (positive scrolls down); -2000 to 2000, not 0 with ticks.
            public var delta: Int
            /// Between ticks, 8 to 200 ms.
            public var tickMilliseconds: Int
        }

        public nonisolated struct Typing: Sendable, Equatable {
            /// 1 to 500 characters, typed by the page itself.
            public var text: String
            /// Type after a draft the composer already holds instead of refusing.
            public var allowDraft: Bool
        }

        public var tab: String
        public var target: Target?
        public var wheel: Wheel?
        public var type: Typing?
        /// How long the hover stays after the last tick, 0 to 10 000 ms.
        public var holdMilliseconds: Int
        /// The whole run's bound, 1 to 30.
        public var seconds: Int
        /// Drive a chat whose turn is running.
        public var allowBusy: Bool

        static let keys: Set<String> = ["tab", "target", "wheel", "type", "hold_ms", "seconds", "allow_busy"]

        public init(_ params: [String: JSONValue]) throws {
            if let unknown = params.keys.sorted().first(where: { !Self.keys.contains($0) }) {
                throw ControlError.invalidParams(String(format: Text.unknownParam, unknown))
            }
            guard let raw = params["tab"]?.stringValue, !raw.isEmpty else { throw ControlError.invalidParams(Text.needsTab) }
            tab = normalizedControlTabID(raw)
            seconds = try Self.whole(params["seconds"], 1...AgentChatDriveControl.maxSeconds, default: AgentChatDriveControl.defaultSeconds,
                                     String(format: Text.seconds, AgentChatDriveControl.maxSeconds))
            holdMilliseconds = try Self.whole(params["hold_ms"], 0...10_000, default: 500, Text.holdMilliseconds)
            allowBusy = try Self.flag(params["allow_busy"], Text.allowBusy)
            target = try Self.target(params["target"])
            wheel = try Self.wheel(params["wheel"])
            type = try Self.typing(params["type"])
            if let wheel, wheel.ticks > 0, target == nil { throw ControlError.invalidParams(Text.wheelNeedsTarget) }
            let ticks = wheel.map { $0.ticks * $0.tickMilliseconds } ?? 0
            if ticks + holdMilliseconds > seconds * 1000 { throw ControlError.invalidParams(Text.tooLong) }
        }

        /// `drive.begin`'s options (the page contract).
        var beginOptions: JSONValue {
            var options: [String: JSONValue] = ["allow_busy": .bool(allowBusy), "seconds": .number(Double(seconds))]
            switch target {
            case .testID(let id)?: options["target"] = ["test_id": .string(id)]
            case .sentImage(let n)?: options["target"] = ["sent_image": .number(Double(n))]
            case .toolScreenshot(let n)?: options["target"] = ["tool_screenshot": .number(Double(n))]
            case nil: break
            }
            if let type { options["type"] = ["text": .string(type.text), "allow_draft": .bool(type.allowDraft)] }
            return .object(options)
        }

        private static func whole(_ value: JSONValue?, _ range: ClosedRange<Int>, default fallback: Int, _ message: String) throws -> Int {
            guard let value else { return fallback }
            guard let number = value.intValue, range.contains(number) else { throw ControlError.invalidParams(message) }
            return number
        }

        private static func flag(_ value: JSONValue?, _ message: String) throws -> Bool {
            guard let value else { return false }
            guard let flag = value.boolValue else { throw ControlError.invalidParams(message) }
            return flag
        }

        private static func target(_ value: JSONValue?) throws -> Target? {
            guard let value else { return nil }
            guard let members = value.objectValue, members.count == 1, let (key, item) = members.first else {
                throw ControlError.invalidParams(Text.target)
            }
            switch key {
            case "test_id":
                guard let id = item.stringValue, isTestID(id) else { throw ControlError.invalidParams(Text.target) }
                return .testID(id)
            case "sent_image", "tool_screenshot":
                guard let n = item.intValue, (1...maxImageIndex).contains(n) else { throw ControlError.invalidParams(Text.target) }
                return key == "sent_image" ? .sentImage(n) : .toolScreenshot(n)
            default:
                throw ControlError.invalidParams(Text.target)
            }
        }

        /// The highest `sent_image` or `tool_screenshot` position (from 1). The CLI checks the same bound
        /// (cmux-tui/spec/fixtures/chat-drive-type-text.json `max_image_index`, read by both sides' tests).
        public static let maxImageIndex = 10_000

        /// `[A-Za-z0-9_-]{1,80}`: a test id is a name, never a selector.
        public static func isTestID(_ id: String) -> Bool {
            (1...80).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
            }
        }

        private static func wheel(_ value: JSONValue?) throws -> Wheel? {
            guard let value else { return nil }
            guard let members = value.objectValue, members.keys.allSatisfy(["ticks", "delta", "tick_ms"].contains) else {
                throw ControlError.invalidParams(Text.wheel)
            }
            let ticks = try whole(members["ticks"], 0...200, default: 0, Text.wheel)
            let delta = try whole(members["delta"], -2000...2000, default: 0, Text.wheel)
            let tick = try whole(members["tick_ms"], 8...200, default: 16, Text.wheel)
            if ticks > 0, delta == 0 { throw ControlError.invalidParams(Text.wheel) }
            return Wheel(ticks: ticks, delta: delta, tickMilliseconds: tick)
        }

        private static func typing(_ value: JSONValue?) throws -> Typing? {
            guard let value else { return nil }
            guard let members = value.objectValue, members.keys.allSatisfy(["text", "allow_draft"].contains),
                  let text = members["text"]?.stringValue, (1...500).contains(text.count), text.utf16.count <= 2000 else {
                throw ControlError.invalidParams(Text.type)
            }
            guard isTypable(text) else { throw ControlError.invalidParams(Text.typeText) }
            return Typing(text: text, allowDraft: try flag(members["allow_draft"], Text.type))
        }

        /// Text the page may type as a person's keys: no C0 or C1 control character (DEL too), no line or
        /// paragraph separator, and no leading `!` (after spaces), which in an empty draft would start a
        /// command; the host can't know whether the draft is empty, so it is refused either way.
        public static func isTypable(_ text: String) -> Bool {
            let controls = text.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
            }
            return !controls && text.drop(while: \.isWhitespace).first != "!"
        }
    }

    // MARK: The page calls (fixed scripts; the caller's values are arguments only)

    static let beginScript = """
        const drive = window.cmuxAcpmuxBridge?.drive;
        if (typeof drive?.begin !== "function") return JSON.stringify({ error: "no_drive" });
        return JSON.stringify(await drive.begin(options));
        """
    static let stateScript = """
        const drive = window.cmuxAcpmuxBridge?.drive;
        if (typeof drive?.state !== "function") return JSON.stringify({ error: "no_drive" });
        return JSON.stringify(await drive.state());
        """
    static let endScript = """
        const drive = window.cmuxAcpmuxBridge?.drive;
        if (typeof drive?.end !== "function") return JSON.stringify({ error: "no_drive" });
        return JSON.stringify(await drive.end());
        """

    /// Why no picture comes with the report.
    nonisolated static let captureNote = "A covered, hidden or screen-locked window draws no frames, so neither the page's frames nor a picture of the pane exist then."
    nonisolated static let noEngineCounters = "WebKit does not expose layout or style counts to the app"

    /// On the main actor: the tab is found, the person's use and a frozen page refused, in the same turn that starts the run.
    @MainActor
    static func run(_ raw: [String: JSONValue], find: @MainActor @Sendable (String) -> ChatPage) async throws -> JSONValue {
        let params = try Params(raw)
        let view: AgentPaneView
        switch find(params.tab) {
        case .missing: throw ControlError(code: "not_found", message: Text.noTab)
        case .notAgentChat: throw ControlError.invalidParams(Text.notAgentChat)
        case .notLoaded: throw ControlError(code: "unavailable", message: Text.pageNotLoaded)
        case .page(let page): view = page
        }
        // A frozen page runs no script, and any call would thaw it first: driving must not wake it.
        guard !view.pageIsFrozen else { throw ControlError(code: "unavailable", message: Text.pageAsleep) }
        guard let window = view.window else { throw ControlError(code: "unavailable", message: Text.noWindow) }
        let person = DrivePerson(view: view, window: window)
        guard !person.isUsing(since: nil) else { throw ControlError(code: "busy", message: Text.personBusy) }

        // A page that threw or gave no object can't be driven (an older page has no `drive`).
        let begun = try? await Self.call(view, beginScript, ["options": params.beginOptions.foundationObject], timeout: .seconds(10))
        switch begun?["error"]?.stringValue {
        case nil where begun?["ok"] == true: break
        case "busy"?: throw ControlError(code: "conflict", message: Text.turnBusy)
        case "running"?: throw ControlError(code: "conflict", message: Text.running)
        case "no_target"?: throw ControlError(code: "not_found", message: Text.noTarget)
        case "target_covered"?: throw ControlError(code: "conflict", message: Text.targetCovered)
        case "draft_not_empty"?: throw ControlError(code: "conflict", message: Text.draftNotEmpty)
        case "no_composer"?: throw ControlError(code: "unavailable", message: Text.noComposer)
        default: throw ControlError(code: "unavailable", message: Text.noDrive)
        }

        // From here the page drives itself until `drive.end()` (or its own backstop at seconds + 2 s).
        let input = view.page.map(AgentChatDriveInput.init(page:)) ?? AgentChatDriveInput(webView: view.webView)
        let release = DriveRelease(input: input)
        // The backstop stays armed until a release went in: the release holds it past this call when none did.
        release.armBackstop(after: .seconds(params.seconds + 2))
        // The tab closing and the view leaving its window release at once, during the run and after it.
        release.register(on: view)
        let surroundings = DriveSurroundings(view: view, window: window)

        var run = DriveRun(params: params, begun: begun ?? [:])
        let how: String
        do {
            try await run.drive(view: view, input: input, person: person, surroundings: surroundings, release: release)
            how = "end"
        } catch is CancellationError {
            how = "cancel"
        } catch {
            how = Task.isCancelled ? "cancel" : "error"
        }
        release.runEnded = true
        // The page's report, whatever happened; never a call that would thaw a page frozen meanwhile.
        var report: [String: JSONValue]?
        if !view.pageIsFrozen { report = (try? await Self.call(view, endScript, [:], timeout: .seconds(10))) ?? nil }
        await release.release(Task.isCancelled ? "cancel" : how)
        let counters = await input.engineCounters(since: run.countersStart)

        var result: [String: JSONValue] = [
            "tab": .string(params.tab),
            "engine": .string(view.engineName),
            "hover": .object(run.hover),
            "wheel": [
                "ticks": .number(Double(params.wheel?.ticks ?? 0)), "delta": .number(Double(params.wheel?.delta ?? 0)),
                "tick_ms": .number(Double(params.wheel?.tickMilliseconds ?? 16)), "sent": .number(Double(run.sent)),
                // What reached the page, not what was sent: its own count of trusted wheels, and how far its
                // transcript moved against `sent` × `delta` (a dropped or coalesced tick shows as a difference).
                "delivered": report?["totals"]?["wheel_trusted"] ?? .null,
                "scrolled": run.scrolled.map { .number($0) } ?? .null,
                "expected": .number(Double(run.sent * (params.wheel?.delta ?? 0))),
            ],
            "interrupted": (run.interrupted ?? release.triggered).map(JSONValue.string) ?? .null,
            "released": .bool(release.released),
            "release": .string(release.how ?? "pending"),
            "release_retries_scheduled": .number(Double(release.released ? 0 : release.laterRoundsLeft)),
            "capture": .null,
            "capture_note": .string(captureNote),
            "page": report.map(JSONValue.object) ?? .null,
        ]
        if input.isChromium {
            result["engine_counters"] = counters.map { JSONValue.object($0.mapValues(JSONValue.number)) } ?? .null
        } else {
            result["engine_counters"] = .null
            result["engine_counters_unavailable"] = .string(noEngineCounters)
        }
        if report == nil { result["page_error"] = .string(view.pageIsFrozen ? "the page froze during the run" : "the page gave no report") }
        return .object(result)
    }

    /// One fixed page script with `arguments`; its JSON object, or nil when the page gave none.
    @MainActor
    static func call(_ view: AgentPaneView, _ script: String, _ arguments: [String: Any], timeout: Duration) async throws -> [String: JSONValue]? {
        let value = try await view.callPageScript(script, arguments: arguments, timeout: timeout)
        guard let text = value as? String, case .object(let object)? = try? JSONValue.parse(Data(text.utf8)) else { return nil }
        return object
    }

    /// The refusals, in this package's Localizable.xcstrings (`agentPane.chatDrive.*`).
    nonisolated enum Text {
        static var unknownParam: String { String(localized: "agentPane.chatDrive.unknownParam", defaultValue: "%@ isn't a parameter of agent.chat.drive.", bundle: .module) }
        static var needsTab: String { String(localized: "agentPane.chatDrive.needsTab", defaultValue: "Name the chat tab to drive.", bundle: .module) }
        static var seconds: String { String(localized: "agentPane.chatDrive.seconds", defaultValue: "seconds must be a whole number from 1 to %lld", bundle: .module) }
        static var holdMilliseconds: String {
            String(localized: "agentPane.chatDrive.holdMilliseconds", defaultValue: "hold_ms must be a whole number from 0 to 10000", bundle: .module)
        }
        static var allowBusy: String { String(localized: "agentPane.chatDrive.allowBusy", defaultValue: "allow_busy must be true or false", bundle: .module) }
        static var target: String {
            String(localized: "agentPane.chatDrive.target",
                   defaultValue: "target takes one of test_id (1 to 80 letters, digits, - or _), sent_image or tool_screenshot (a whole number from 1)",
                   bundle: .module)
        }
        static var wheel: String {
            String(localized: "agentPane.chatDrive.wheel",
                   defaultValue: "wheel takes ticks (0 to 200), delta (a whole number of pixels from -2000 to 2000, not 0) and tick_ms (8 to 200)",
                   bundle: .module)
        }
        static var wheelNeedsTarget: String {
            String(localized: "agentPane.chatDrive.wheelNeedsTarget", defaultValue: "A wheel needs a target to hold the pointer over.", bundle: .module)
        }
        static var typeText: String {
            String(localized: "agentPane.chatDrive.typeText",
                   defaultValue: "type.text can't hold control characters or line separators, or start with !", bundle: .module)
        }
        static var type: String {
            String(localized: "agentPane.chatDrive.type",
                   defaultValue: "type takes text (1 to 500 characters, at most 2000 UTF-16 units) and allow_draft (true or false)", bundle: .module)
        }
        static var tooLong: String {
            String(localized: "agentPane.chatDrive.tooLong", defaultValue: "The wheel ticks and the hold take longer than seconds allows.", bundle: .module)
        }
        static var noTab: String { String(localized: "agentPane.chatDrive.noTab", defaultValue: "That tab is no longer open.", bundle: .module) }
        static var notAgentChat: String { String(localized: "agentPane.chatDrive.notAgentChat", defaultValue: "That tab isn't an agent chat.", bundle: .module) }
        static var pageNotLoaded: String {
            String(localized: "agentPane.chatDrive.pageNotLoaded", defaultValue: "That chat's page isn't loaded. Open the chat once, then drive it again.", bundle: .module)
        }
        static var pageAsleep: String {
            String(localized: "agentPane.chatDrive.pageAsleep",
                   defaultValue: "That chat's page is asleep while it's hidden, and driving doesn't wake it. Show the chat, then drive it again.",
                   bundle: .module)
        }
        static var noWindow: String {
            String(localized: "agentPane.chatDrive.noWindow", defaultValue: "That chat isn't in a window, so it can't take a pointer.", bundle: .module)
        }
        static var personBusy: String {
            String(localized: "agentPane.chatDrive.personBusy", defaultValue: "The person is using that chat. Try again when they're done with it.", bundle: .module)
        }
        static var noDrive: String {
            String(localized: "agentPane.chatDrive.noDrive", defaultValue: "That chat's page can't be driven. Update cmux, then try again.", bundle: .module)
        }
        static var running: String {
            String(localized: "agentPane.chatDrive.running", defaultValue: "That chat is already being driven. Try again when that run ends.", bundle: .module)
        }
        static var turnBusy: String {
            String(localized: "agentPane.chatDrive.turnBusy", defaultValue: "That chat is running a turn. Try again when it ends, or allow a busy chat.", bundle: .module)
        }
        static var noTarget: String { String(localized: "agentPane.chatDrive.noTarget", defaultValue: "That chat shows no such element.", bundle: .module) }
        static var targetCovered: String {
            String(localized: "agentPane.chatDrive.targetCovered", defaultValue: "Something covers that element, so the pointer can't reach it.", bundle: .module)
        }
        static var draftNotEmpty: String {
            String(localized: "agentPane.chatDrive.draftNotEmpty", defaultValue: "That chat's composer holds a draft. Clear it, or allow typing after the draft.", bundle: .module)
        }
        static var noComposer: String { String(localized: "agentPane.chatDrive.noComposer", defaultValue: "That chat has no composer to type in.", bundle: .module) }
    }
}

/// One run between `drive.begin` and `drive.end`: the hover, the wheel ticks and the hold.
private struct DriveRun {
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
            let before = try await Self.scrollTop(view)
            let stopped = try await wheelTicks(wheel, at: point, view: view, input: input, person: person, release: release,
                                               started: started, stop: stop)
            // The page's own scroll, once WebKit has handled what was sent: what the ticks really moved.
            await input.settle()
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
            if await input.wheel(at: point, deltaY: Double(wheel.delta)) { sent += 1 }
            if tick + 1 < wheel.ticks {
                // Between two ticks (up to 200 ms apart) the person, the window and the app are watched every
                // DriveWatch.step, as in a hold; what it sees, the next tick's checks act on at once.
                let surroundings = surroundings
                _ = try await DriveWatch.watch(until: ContinuousClock.now + .milliseconds(wheel.tickMilliseconds), isUsing: {
                    Self.outside(surroundings, release) != nil || person.isUsing(since: started)
                })
            }
        }
        return false
    }

    /// The transcript's scroll offset as the page reads it (`drive.state().scroll_top`), or nil.
    static func scrollTop(_ view: AgentPaneView) async throws -> Double? {
        guard !view.pageIsFrozen else { return nil }
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

/// Gives the hover back, once, whichever path gets there first: the run's end, an error, a cancelled
/// call, the person, the backstop timer, or a trigger from outside the run (the tab closing, the window
/// closing, the app resigning active); `how` says which. Only a release that went in counts, and one
/// that can't is retried, bounded: after a failed send it waits ``retryWaits`` (50 ms doubling to 1 s,
/// 9 sends in about 4.5 s). One round runs at a time; a release asked for during a round joins it.
/// A view that is gone (``AgentChatDriveInput/ReleaseOutcome/gone``) holds no hover: that counts as
/// released by `teardown`. Past the cap the release stays pending, registered on its view
/// (``AgentPaneView/heldDrives``), and the view's next trigger (back in a window, the tab closing)
/// runs another round; so do at most 3 later rounds (``laterRounds``: 2 s, 10 s and 30 s after a
/// failed round), and the person's real pointer in the pane (``DrivePointerWatch``) ends it: WebKit's
/// hover follows that pointer, so nothing synthetic is left. The registration lasts until a release went in. The run itself reads the
/// window and the app (``DriveSurroundings``) with the person: no observer of its own.
@MainActor
final class DriveRelease {
    typealias Outcome = AgentChatDriveInput.ReleaseOutcome

    /// The waits between the sends of one round.
    static let retryWaits: [Duration] = [50, 100, 200, 400, 800, 1000, 1000, 1000].map { Duration.milliseconds($0) }
    /// The triggers that stop a run that is still going (`interrupted`); the others only retry a pending release.
    static let interrupting: Set<String> = ["teardown", "window_close", "resign", "detached"]
    /// The trigger that can make a send go in that failed before (the view back in a window): one that
    /// comes while a round runs gets a round of its own after it, never only the rest of that one. A
    /// teardown needs none: the round ends at its next send (``tornDown``).
    static let fresh: Set<String> = ["window"]
    /// The waits before the later rounds, each after a round that failed: at most 3 more rounds.
    static let laterRounds: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]

    /// Sends the pointer-leave.
    private let send: @MainActor () async -> Outcome
    /// Waits between two sends of a round (tests pass their own).
    private let sleep: @MainActor (Duration) async -> Void
    /// A move went in, or is on its way, so there is a hover to give back.
    var armed = false
    /// The run returned: a trigger from now on only retries the release.
    var runEnded = false
    /// The path whose release went in; nil until one did.
    private(set) var how: String?
    private(set) var released = false
    /// The first trigger from outside the run while it was still going; the run stops at it.
    private(set) var triggered: String?
    /// The sends made, for the report and tests.
    private(set) var sends = 0
    /// The round running now; a release asked for meanwhile waits for it.
    private var round: Task<Void, Never>?
    /// The tab closed: whatever the next send does, nothing is left to hold.
    private var tornDown = false
    /// The deadline that releases even when the run never gets there; dropped once a release went in.
    private var backstop: DemandTimer?
    private weak var view: AgentPaneView?
    /// The waits before the later rounds (tests pass their own).
    private let later: [Duration]
    /// The later rounds still to come; the result reports it while the release is pending.
    private(set) var laterRoundsLeft: Int
    /// The next later round's deadline; dropped once a release went in.
    private var laterTimer: DemandTimer?
    /// The person's real pointer in the pane ends a pending release (held here: a tracking area does not keep its owner).
    var pointerWatch: DrivePointerWatch?

    init(input: AgentChatDriveInput) {
        send = { await input.release() }
        sleep = DriveRelease.pause
        later = Self.laterRounds
        laterRoundsLeft = later.count
    }

    init(send: @escaping @MainActor () async -> Outcome, sleep: @escaping @MainActor (Duration) async -> Void = DriveRelease.pause,
         later: [Duration] = DriveRelease.laterRounds) {
        self.send = send
        self.sleep = sleep
        self.later = later
        laterRoundsLeft = later.count
    }

    /// A later round is waiting for its deadline.
    var isLaterRoundScheduled: Bool { laterTimer?.isScheduled == true }

    static func pause(_ delay: Duration) async {
        // wakeup-allow: one wait between two release sends (at most 1 s, 8 a round), in the round's own task
        try? await Task.sleep(for: delay)
    }

    var isDone: Bool { released }

    /// Arms the main-queue deadline `delay` from now. It holds this release until it fires or a release went in.
    func armBackstop(after delay: Duration) {
        let timer = DemandTimer(owner: "agent.chat-drive.release")
        timer.schedule(after: delay) { @MainActor in await self.release("timer") }
        backstop = timer
    }

    var isBackstopArmed: Bool { backstop?.isScheduled == true }

    /// Registers on `view` until a release went in: the tab closing and the view moving between
    /// windows (``AgentPaneView/heldDrives``) trigger it, and the person's real pointer in it ends it.
    func register(on view: AgentPaneView) {
        guard !released else { return }
        self.view = view
        view.heldDrives[ObjectIdentifier(self)] = self
        DrivePointerWatch(release: self).install(on: view)
    }

    /// The person's real pointer moved in, into or out of the pane (``DrivePointerWatch``). During the
    /// run that is the person: the run stops and releases. After it, WebKit's hover follows that pointer,
    /// so a pending release is done (`person_pointer`) with no send.
    func personPointer() {
        guard !released else { return }
        guard runEnded else {
            if triggered == nil { triggered = "person" }
            // task-owner: one bounded release round (about 4.5 s at most), joined by a round already running
            // main-hop-allow: the person's pointer ends the run: one pointer-leave per send, at most 9 sends a round
            Task { @MainActor in await self.release("person") }
            return
        }
        finish("person_pointer")
    }

    /// Something outside the run happened (`teardown`, `window_close`, `resign`, `detached`, `window`).
    /// A run still going stops at an interrupting one and the release starts at once; after the run,
    /// every trigger retries a release that is still pending.
    func trigger(_ name: String) {
        guard !released else { return }
        if name == "teardown" { tornDown = true }
        let interrupts = Self.interrupting.contains(name)
        if !runEnded {
            guard interrupts else { return }
            if triggered == nil { triggered = name }
        }
        // task-owner: one bounded release round (about 4.5 s at most), joined by a round already running
        // main-hop-allow: a trigger's release is not frame work: one pointer-leave per send, at most 9 sends a round
        Task { @MainActor in await self.release(name, fresh: Self.fresh.contains(name)) }
    }

    /// Its view moved to another window or out of every one (``AgentPaneView/viewDidMoveToWindow()``).
    func viewMoved(inWindow: Bool) {
        trigger(inWindow ? "window" : "detached")
    }

    /// Gives the hover back: one bounded round of sends, or the round already running. With `fresh` (a
    /// trigger in ``fresh``), a round already running that ends without the release is followed by a new one.
    func release(_ reason: String, fresh: Bool = false) async {
        guard !released else { return }
        if let round {
            await round.value
            // That round's sends came before this event; one after it can now go in.
            guard fresh else { return }
            return await release(reason)
        }
        // The round clears itself as it ends, so a release asked for after it starts the next one.
        // main-hop-allow: its own task so a cancelled call can't cut the round short; one pointer-leave per send, at most 9
        let attempt = Task { @MainActor in
            await self.retry(reason)
            self.round = nil
            if !self.released { self.scheduleLater() }
        }
        round = attempt
        await attempt.value
    }

    /// One round: a send, and after each failed one a wait from ``retryWaits`` and another send.
    private func retry(_ reason: String) async {
        for wait in [Duration.zero] + Self.retryWaits {
            // wakeup-allow: the spacing after a failed send (50 ms doubling to 1 s, 8 in a round, about 4.5 s); the
            // event that can make it succeed (the view back in a window, the tab closing) starts the next round
            if wait > .zero { await sleep(wait) }
            guard !released else { return }
            // Nothing was moved: the page's hover is already the person's pointer's.
            guard armed else { return finish(tornDown ? "teardown" : reason) }
            sends += 1
            switch await send() {
            case .wentIn: return finish(tornDown ? "teardown" : reason)
            case .gone: return finish("teardown")
            case .failed: if tornDown { return finish("teardown") }
            }
        }
    }

    /// After a round that failed: the next later round, when one is left and none waits yet.
    private func scheduleLater() {
        guard laterRoundsLeft > 0, !isLaterRoundScheduled else { return }
        let timer = laterTimer ?? DemandTimer(owner: "agent.chat-drive.release-later")
        laterTimer = timer
        timer.schedule(after: later[later.count - laterRoundsLeft]) { @MainActor in
            guard !self.released else { return }
            self.laterRoundsLeft -= 1
            await self.release("later", fresh: true)
        }
    }

    private func finish(_ reason: String) {
        // A send in flight may answer after another path ended it: the first one stands.
        guard !released else { return }
        released = true
        how = reason
        backstop?.cancel()
        backstop = nil
        laterTimer?.cancel()
        laterTimer = nil
        pointerWatch?.remove()
        pointerWatch = nil
        view?.heldDrives[ObjectIdentifier(self)] = nil
    }
}

/// The window and the app a run drives in, read with the person (at most 100 ms apart, and before
/// each wheel tick): what outside the run ended it. No observer: a run reads them while it goes.
@MainActor
struct DriveSurroundings {
    /// The view's window now.
    let windowNow: @MainActor () -> NSWindow?
    /// The window the run started in.
    let window: NSWindow
    let isVisible: @MainActor () -> Bool
    let isActive: @MainActor () -> Bool
    /// The app was active when the run started: only a resign after that is one.
    let wasActive: Bool

    init(windowNow: @escaping @MainActor () -> NSWindow?, window: NSWindow, isVisible: @escaping @MainActor () -> Bool,
         isActive: @escaping @MainActor () -> Bool) {
        self.windowNow = windowNow
        self.window = window
        self.isVisible = isVisible
        self.isActive = isActive
        wasActive = isActive()
    }

    init(view: AgentPaneView, window: NSWindow) {
        self.init(windowNow: { [weak view] in view?.window }, window: window, isVisible: { [weak window] in window?.isVisible == true },
                  isActive: { NSApp.isActive })
    }

    /// `detached` (the view left every window), `window_close` (it is in another window now, or its
    /// window closed or is no longer shown), `resign` (the app was active and is not), or nil.
    func trigger() -> String? {
        guard let now = windowNow() else { return "detached" }
        if now !== window || !isVisible() { return "window_close" }
        if wasActive, !isActive() { return "resign" }
        return nil
    }
}

/// Whether the person is using the chat: their real pointer is over its pane (and no other window
/// covers it there), or their own key or click reached it within ``AgentChatDriveControl/personQuietSeconds``
/// (or, with `since`, after the run started).
@MainActor
private struct DrivePerson {
    let view: AgentPaneView
    let window: NSWindow

    func isUsing(since started: TimeInterval?) -> Bool {
        let mouse = NSEvent.mouseLocation
        if AgentChatDriveInput.isTopmost(window, at: mouse),
           window.convertToScreen(view.convert(view.visibleRect, to: nil)).contains(mouse) { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let quiet = AgentChatDriveControl.personQuietSeconds
        if let page = view.page {
            // The page's own record of a real key or button that reached it (page script cannot set it).
            guard let last = page.lastUserEventUptime else { return false }
            return now - last <= quiet || started.map { last >= $0 } == true
        }
        // The pane's own WebKit host keeps no such record: a key or click anywhere in the session
        // while this chat holds the keyboard in the key window counts as the person's.
        guard window.isKeyWindow, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return false }
        let since = min(quiet, started.map { now - $0 } ?? quiet)
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown].contains { type in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) <= since
        }
    }
}
