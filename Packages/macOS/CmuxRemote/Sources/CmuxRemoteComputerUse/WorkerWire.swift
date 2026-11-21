// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import Foundation

/// The Computer Use worker's control lines (the worker contract of the cmux Computer Use
/// rewrite): JSON lines on the worker's stdin and stdout, between it and the cmux Remote host.
///
///     host -> worker  {"type":"configure","config":<PolicyConfig>,"socket":P,"secret":HEX,"state_dir":D,"machine":M}
///     worker -> host  {"type":"ready","pid":N,"socket":P}  or  {"type":"unavailable","reason":R}
///     host -> worker  {"type":"config","config":<PolicyConfig>}
///     host -> worker  {"type":"approvals","action":"forget|always|never|revoke_sessions|list","app_id":ID}
///     worker -> host  {"type":"request_permission","permission":"accessibility|screen-recording"}
///     host -> worker  {"type":"session","action":"stop|resume","session":S,"label":L,"id":N}
///     host -> worker  {"type":"cursor/spotlight","session":S,"id":N}
///     host -> worker  {"type":"window/raise","session":S,"id":N}
///
/// A host line may carry `"id":N`; the worker then answers `{"id":N,"ok":...}` (RemoteWire). The
/// macOS-only `motion` object (`{"enabled":B,"speed":S}`, the app's animation switches for the
/// cursor category) may ride on `configure` and `config`.
enum WorkerControl: Equatable, Sendable {
    case configure(WorkerConfiguration)
    case config(policy: Data, motion: CursorMotionSettings?)
    case approvals(id: Int?, action: ApprovalEdit)
    /// The person's Stop or Resume of one agent session (the cmux menu bar).
    case session(id: Int?, SessionControl)
    /// Show Cursor: ring the session's agent cursor where it is (or last was).
    case spotlight(id: Int?, session: String)
    /// Show Window: raise the window the session works in, within its app.
    case raiseWindow(id: Int?, session: String)
    /// A line this worker does not know (ignored, answered when it has an id).
    case unknown(id: Int?, type: String)

    init?(line: [String: Any]) {
        let id = line["id"] as? Int
        switch line["type"] as? String {
        case "configure":
            guard let configuration = WorkerConfiguration(line: line) else { return nil }
            self = .configure(configuration)
        case "config":
            guard let policy = PolicyFlags.data(line["config"]) else { return nil }
            self = .config(policy: policy, motion: CursorMotionSettings(line["motion"]))
        case "approvals":
            if let edit = ApprovalEdit(action: line["action"] as? String, appID: line["app_id"] as? String) {
                self = .approvals(id: id, action: edit)
            } else {
                self = .unknown(id: id, type: "approvals")
            }
        case "session":
            guard let control = SessionControl(line: line) else { self = .unknown(id: id, type: "session"); return }
            self = .session(id: id, control)
        case "cursor/spotlight", "window/raise":
            guard let session = SessionControl.sessionKey(line["session"]) else {
                self = .unknown(id: id, type: line["type"] as? String ?? "")
                return
            }
            self = line["type"] as? String == "cursor/spotlight" ? .spotlight(id: id, session: session) : .raiseWindow(id: id, session: session)
        case let type:
            self = .unknown(id: id, type: type ?? "")
        }
    }
}

/// The first line: what the worker serves and where.
struct WorkerConfiguration: Equatable, Sendable {
    /// The PolicyConfig JSON (policy.rs), passed to the engine as is.
    var policy: Data
    var socket: String
    var secret: String
    var stateDirectory: String
    var machine: String
    var motion: CursorMotionSettings

    init(policy: Data, socket: String, secret: String, stateDirectory: String, machine: String,
         motion: CursorMotionSettings = CursorMotionSettings()) {
        self.policy = policy
        self.socket = socket
        self.secret = secret
        self.stateDirectory = stateDirectory
        self.machine = machine
        self.motion = motion
    }

    init?(line: [String: Any]) {
        guard let policy = PolicyFlags.data(line["config"] ?? [String: Any]()),
              let socket = line["socket"] as? String, socket.hasPrefix("/"),
              let secret = line["secret"] as? String, RemoteWire.unhex(secret).map({ $0.count >= 16 }) == true,
              let state = line["state_dir"] as? String, state.hasPrefix("/") else { return nil }
        self.init(policy: policy, socket: socket, secret: secret, stateDirectory: state,
                  machine: line["machine"] as? String ?? "", motion: CursorMotionSettings(line["motion"]) ?? CursorMotionSettings())
    }

    var line: Data {
        var fields: [String: Any] = ["type": "configure", "socket": socket, "secret": secret, "state_dir": stateDirectory,
                                     "machine": machine, "motion": motion.fields]
        fields["config"] = (try? JSONSerialization.jsonObject(with: policy)) ?? [String: Any]()
        return RemoteWire.line(fields)
    }
}

/// The few PolicyConfig fields the worker itself acts on (the engine reads the whole config).
struct PolicyFlags: Equatable, Sendable {
    var mode: String = "fullAccess"
    var showCursor = true
    var pauseOnTakeover = true
    /// When an agent cursor shows its tag (`computerUse.cursorTag`): `hover`, `always` or `never`.
    var cursorTag = CursorTagMode.hover

    init() {}

    init(_ policy: Data) {
        let object = (try? JSONSerialization.jsonObject(with: policy)) as? [String: Any] ?? [:]
        if let mode = object["mode"] as? String { self.mode = mode }
        if let show = object["showCursor"] as? Bool { showCursor = show }
        if let pause = object["pauseOnTakeover"] as? Bool { pauseOnTakeover = pause }
        if let tag = (object["cursorTag"] as? String).flatMap(CursorTagMode.init(rawValue:)) { cursorTag = tag }
    }

    var isOff: Bool { mode == "off" }

    /// A PolicyConfig object as JSON bytes; nil when `value` is not an object.
    static func data(_ value: Any?) -> Data? {
        guard let object = value as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// `computerUse.cursorTag`: when an agent cursor shows its tag (the agent's workspace name, or the
/// tag it set): while the person's pointer is over the cursor, always, or never.
enum CursorTagMode: String, Equatable, Sendable {
    case hover, always, never
}

/// The person's Stop or Resume of one agent session (`cmux_cu_engine_session`).
struct SessionControl: Equatable, Sendable {
    enum Action: String, Sendable {
        case stop, resume
    }

    var action: Action
    var session: String
    /// The agent's name, for the cursor's Stopped chip.
    var label: String

    init(action: Action, session: String, label: String = "") {
        self.action = action
        self.session = session
        self.label = label
    }

    init?(line: [String: Any]) {
        guard let action = (line["action"] as? String).flatMap(Action.init(rawValue:)),
              let session = Self.sessionKey(line["session"]) else { return nil }
        self.init(action: action, session: session, label: line["label"] as? String ?? "")
    }

    /// An engine session key: non-empty, at most 256 bytes.
    static func sessionKey(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256 else { return nil }
        return text
    }
}

/// An approvals edit (`cmux_cu_engine_edit_approvals`), or the saved list.
enum ApprovalEdit: Equatable, Sendable {
    case forget(String)
    case always(String)
    case never(String)
    case revokeSessions
    case list

    init?(action: String?, appID: String?) {
        let app = appID.flatMap { $0.isEmpty ? nil : $0 }
        switch action {
        case "forget": guard let app else { return nil }; self = .forget(app)
        case "always": guard let app else { return nil }; self = .always(app)
        case "never": guard let app else { return nil }; self = .never(app)
        case "revoke_sessions": self = .revokeSessions
        case "list": self = .list
        default: return nil
        }
    }

    /// The engine's action word and app id; nil for `list`.
    var engineArguments: (action: String, appID: String)? {
        switch self {
        case .forget(let app): ("forget", app)
        case .always(let app): ("always", app)
        case .never(let app): ("never", app)
        case .revokeSessions: ("revoke_sessions", "")
        case .list: nil
        }
    }
}

/// The cursor category of the app's animation switches (`ui.animations.enabled`,
/// `ui.animations.cursor`, `ui.animationSpeed`), sent by the app because the worker cannot read
/// the app's settings; Reduce Motion is read here, from macOS.
struct CursorMotionSettings: Equatable, Sendable {
    var enabled = true
    /// `ui.animationSpeed`: 2 plays twice as fast.
    var speed = 1.0

    init(enabled: Bool = true, speed: Double = 1.0) {
        self.enabled = enabled
        self.speed = speed
    }

    init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        enabled = object["enabled"] as? Bool ?? true
        let speed = (object["speed"] as? NSNumber)?.doubleValue ?? 1
        self.speed = speed.isFinite && speed > 0 ? min(max(speed, 0.25), 4) : 1
    }

    var fields: [String: Any] { ["enabled": enabled, "speed": speed] }

    /// Whether the cursor animates now: the app's switches and macOS Reduce Motion.
    func animates(reduceMotion: Bool) -> Bool { enabled && !reduceMotion }
}

/// The worker's own lines to the host.
struct WorkerReport: Sendable {
    static func ready(pid: pid_t, socket: String) -> Data {
        RemoteWire.line(["type": "ready", "pid": Int(pid), "socket": socket])
    }

    static func unavailable(_ reason: String) -> Data {
        RemoteWire.line(["type": "unavailable", "reason": reason])
    }

    /// `name` as the C ABI names it ("accessibility", "screen_capture"), as cmux Remote names it.
    static func requestPermission(_ name: String) -> Data? {
        let permission: RemotePermission
        switch name {
        case "accessibility": permission = .accessibility
        case "screen_capture", "screen_recording", "screen-recording": permission = .screenRecording
        default: return nil
        }
        return RemoteWire.line(["type": "request_permission", "permission": permission.rawValue])
    }
}

/// One `ask` question (cmux_computer_use.h): `{"session","agent","app":{"id","name"},"remember","from_machine"}`.
struct ApprovalQuestion: Equatable, Sendable {
    var session: String
    var agent: String
    var appID: String
    var appName: String
    /// Offer Always Allow and Never (Approved apps mode).
    var remember: Bool
    var fromMachine: String?

    init(session: String, agent: String, appID: String, appName: String, remember: Bool, fromMachine: String? = nil) {
        self.session = session
        self.agent = agent
        self.appID = appID
        self.appName = appName
        self.remember = remember
        self.fromMachine = fromMachine
    }

    init?(json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let app = object["app"] as? [String: Any] else { return nil }
        let id = app["id"] as? String ?? ""
        let name = (app["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        guard !name.isEmpty else { return nil }
        self.init(session: object["session"] as? String ?? "", agent: (object["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "",
                  appID: id, appName: name, remember: object["remember"] as? Bool ?? false,
                  fromMachine: (object["from_machine"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The answers the panel offers, in their order on screen.
    var choices: [ApprovalAnswer] {
        remember ? [.never, .deny, .always, .allowSession, .allowOnce] : [.deny, .allowSession, .allowOnce]
    }
}

/// `CMUX_CU_ANSWER_*`.
enum ApprovalAnswer: Int32, CaseIterable, Sendable {
    case unavailable = 0
    case allowOnce = 1
    case allowSession = 2
    case always = 3
    case deny = 4
    case never = 5
}

/// Where `capture` reads: `{"window":"<CGWindowID>"}` or `{"display":null|"<id>","exclude_pids":[N]}`.
/// `exclude_pids`: the processes (denied and protected apps) whose windows the compositor leaves out
/// of a display capture, at every window level, so an agent never sees them.
enum CaptureTarget: Equatable, Sendable {
    case window(UInt32)
    /// Nil: the main display.
    case display(UInt32?, excluding: [pid_t] = [])

    init?(json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        if let window = object["window"] {
            guard let id = Self.number(window) else { return nil }
            self = .window(id)
        } else if object.keys.contains("display") {
            var excluding: [pid_t] = []
            if let list = object["exclude_pids"] {
                guard let numbers = list as? [NSNumber] else { return nil }
                for number in numbers {
                    guard let pid = pid_t(exactly: number.int64Value), pid > 0 else { return nil }
                    excluding.append(pid)
                }
            }
            let display = object["display"]
            if display == nil || display is NSNull {
                self = .display(nil, excluding: excluding)
                return
            }
            guard let id = Self.number(display) else { return nil }
            self = .display(id, excluding: excluding)
        } else {
            return nil
        }
    }

    private static func number(_ value: Any?) -> UInt32? {
        if let text = value as? String { return UInt32(text) }
        return (value as? NSNumber).flatMap { UInt32(exactly: $0.int64Value) }
    }
}
