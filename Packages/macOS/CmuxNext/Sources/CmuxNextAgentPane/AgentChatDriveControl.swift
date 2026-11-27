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
        // timeout: only how long the drive waits for a stalled page to start its run; the call then refuses, and nothing the person does waits on it
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
        // timeout: only how long the drive waits for a stalled page's report; it then answers without one and still releases the hover
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
                "per_tick": .array(run.perTick),
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
        static var unknownParam: String { String(localized: "agentPane.chatDrive.unknownParam", defaultValue: "%@ isn't a parameter of agent.chat.drive.", bundle: .localizedModule) }
        static var needsTab: String { String(localized: "agentPane.chatDrive.needsTab", defaultValue: "Name the chat tab to drive.", bundle: .localizedModule) }
        static var seconds: String { String(localized: "agentPane.chatDrive.seconds", defaultValue: "seconds must be a whole number from 1 to %lld", bundle: .localizedModule) }
        static var holdMilliseconds: String {
            String(localized: "agentPane.chatDrive.holdMilliseconds", defaultValue: "hold_ms must be a whole number from 0 to 10000", bundle: .localizedModule)
        }
        static var allowBusy: String { String(localized: "agentPane.chatDrive.allowBusy", defaultValue: "allow_busy must be true or false", bundle: .localizedModule) }
        static var target: String {
            String(localized: "agentPane.chatDrive.target",
                   defaultValue: "target takes one of test_id (1 to 80 letters, digits, - or _), sent_image or tool_screenshot (a whole number from 1)",
                   bundle: .localizedModule)
        }
        static var wheel: String {
            String(localized: "agentPane.chatDrive.wheel",
                   defaultValue: "wheel takes ticks (0 to 200), delta (a whole number of pixels from -2000 to 2000, not 0) and tick_ms (8 to 200)",
                   bundle: .localizedModule)
        }
        static var wheelNeedsTarget: String {
            String(localized: "agentPane.chatDrive.wheelNeedsTarget", defaultValue: "A wheel needs a target to hold the pointer over.", bundle: .localizedModule)
        }
        static var typeText: String {
            String(localized: "agentPane.chatDrive.typeText",
                   defaultValue: "type.text can't hold control characters or line separators, or start with !", bundle: .localizedModule)
        }
        static var type: String {
            String(localized: "agentPane.chatDrive.type",
                   defaultValue: "type takes text (1 to 500 characters, at most 2000 UTF-16 units) and allow_draft (true or false)", bundle: .localizedModule)
        }
        static var tooLong: String {
            String(localized: "agentPane.chatDrive.tooLong", defaultValue: "The wheel ticks and the hold take longer than seconds allows.", bundle: .localizedModule)
        }
        static var noTab: String { String(localized: "agentPane.chatDrive.noTab", defaultValue: "That tab is no longer open.", bundle: .localizedModule) }
        static var notAgentChat: String { String(localized: "agentPane.chatDrive.notAgentChat", defaultValue: "That tab isn't an agent chat.", bundle: .localizedModule) }
        static var pageNotLoaded: String {
            String(localized: "agentPane.chatDrive.pageNotLoaded", defaultValue: "That chat's page isn't loaded. Open the chat once, then drive it again.", bundle: .localizedModule)
        }
        static var pageAsleep: String {
            String(localized: "agentPane.chatDrive.pageAsleep",
                   defaultValue: "That chat's page is asleep while it's hidden, and driving doesn't wake it. Show the chat, then drive it again.",
                   bundle: .localizedModule)
        }
        static var noWindow: String {
            String(localized: "agentPane.chatDrive.noWindow", defaultValue: "That chat isn't in a window, so it can't take a pointer.", bundle: .localizedModule)
        }
        static var personBusy: String {
            String(localized: "agentPane.chatDrive.personBusy", defaultValue: "The person is using that chat. Try again when they're done with it.", bundle: .localizedModule)
        }
        static var noDrive: String {
            String(localized: "agentPane.chatDrive.noDrive", defaultValue: "That chat's page can't be driven. Update cmux, then try again.", bundle: .localizedModule)
        }
        static var running: String {
            String(localized: "agentPane.chatDrive.running", defaultValue: "That chat is already being driven. Try again when that run ends.", bundle: .localizedModule)
        }
        static var turnBusy: String {
            String(localized: "agentPane.chatDrive.turnBusy", defaultValue: "That chat is running a turn. Try again when it ends, or allow a busy chat.", bundle: .localizedModule)
        }
        static var noTarget: String { String(localized: "agentPane.chatDrive.noTarget", defaultValue: "That chat shows no such element.", bundle: .localizedModule) }
        static var targetCovered: String {
            String(localized: "agentPane.chatDrive.targetCovered", defaultValue: "Something covers that element, so the pointer can't reach it.", bundle: .localizedModule)
        }
        static var draftNotEmpty: String {
            String(localized: "agentPane.chatDrive.draftNotEmpty", defaultValue: "That chat's composer holds a draft. Clear it, or allow typing after the draft.", bundle: .localizedModule)
        }
        static var noComposer: String { String(localized: "agentPane.chatDrive.noComposer", defaultValue: "That chat has no composer to type in.", bundle: .localizedModule) }
    }
}
