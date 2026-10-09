public import CmuxMobileWire
public import CmuxBrowserStream

/// One `desktop/1` control message (c3-rd.md 2.3), carried as rd
/// `{t: "service", service: "desktop/1", body}` on the `rd` channel.
/// Vectors: `schemas/remote-desktop/desktop.json`.
public enum DesktopMessage: Hashable, Sendable {
    /// Phone: show this target rect at this encode size.
    case view(DesktopView)
    /// Mac: the clamped view; the next frame is a keyframe of it.
    case viewApplied(DesktopView)
    /// Mac: the target's size or name changed (VNC connected or resized, display switched).
    case target(DesktopTargetInfo)
    /// Phone: switch to another display.
    case select(display: UInt32)
    case windowsList
    case windows([DesktopWindow])
    case mode(DesktopMode)
    /// Mac: the mode in force; `reason` says why control was not granted.
    case modeApplied(mode: DesktopMode, reason: String?)
    /// Phone: the text to paste, right before the paste key.
    case clipboardPush(seq: UInt32, text: String)
    /// Phone: "copy from Mac".
    case clipboardPull(seq: UInt32)
    /// Mac: text for the phone's pasteboard (`seq` answers a pull; nil for VNC cut text).
    case clipboard(seq: UInt32?, text: String)
    /// Phone: the VNC password, only after `state(.authRequired)`.
    case auth(password: String)
    case state(DesktopState, reason: String?)
    case ended(reason: String)

    public static let service = "desktop/1"
    /// Longest clipboard text either side sends.
    public static let maxClipboardBytes = 256 * 1024

    public var jsonValue: JSONValue {
        var out: [String: JSONValue]
        switch self {
        case .view(let view):
            out = view.jsonMembers
            out["t"] = .string("desktop.view")
        case .viewApplied(let view):
            out = view.jsonMembers
            out["t"] = .string("desktop.view_applied")
        case .target(let info):
            out = ["t": .string("desktop.target"), "target": info.jsonValue]
        case .select(let display):
            out = ["t": .string("desktop.select"), "display": .int(Int64(display))]
        case .windowsList:
            out = ["t": .string("desktop.windows.list")]
        case .windows(let windows):
            out = ["t": .string("desktop.windows"), "windows": .array(windows.map(\.jsonValue))]
        case .mode(let mode):
            out = ["t": .string("desktop.mode"), "mode": .string(mode.rawValue)]
        case .modeApplied(let mode, let reason):
            out = ["t": .string("desktop.mode_applied"), "mode": .string(mode.rawValue)]
            if let reason { out["reason"] = .string(reason) }
        case .clipboardPush(let seq, let text):
            out = ["t": .string("desktop.clipboard.push"), "seq": .int(Int64(seq)), "text": .string(text)]
        case .clipboardPull(let seq):
            out = ["t": .string("desktop.clipboard.pull"), "seq": .int(Int64(seq))]
        case .clipboard(let seq, let text):
            out = ["t": .string("desktop.clipboard"), "text": .string(text)]
            if let seq { out["seq"] = .int(Int64(seq)) }
        case .auth(let password):
            out = ["t": .string("desktop.auth"), "password": .string(password)]
        case .state(let state, let reason):
            out = ["t": .string("desktop.state"), "state": .string(state.rawValue)]
            if let reason { out["reason"] = .string(reason) }
        case .ended(let reason):
            out = ["t": .string("desktop.ended"), "reason": .string(reason)]
        }
        return .object(out)
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try DesktopJSON(json)
        switch try r.string("t") {
        case "desktop.view": self = .view(try DesktopView(reader: r))
        case "desktop.view_applied": self = .viewApplied(try DesktopView(reader: r))
        case "desktop.target": self = .target(try DesktopTargetInfo(json: try r.value("target")))
        case "desktop.select": self = .select(display: try r.uint32("display"))
        case "desktop.windows.list": self = .windowsList
        case "desktop.windows": self = .windows(try r.array("windows").map { (v) throws(RdWireError) in try DesktopWindow(json: v) })
        case "desktop.mode": self = .mode(try Self.mode(r))
        case "desktop.mode_applied": self = .modeApplied(mode: try Self.mode(r), reason: r.optionalString("reason"))
        case "desktop.clipboard.push": self = .clipboardPush(seq: try r.uint32("seq"), text: try Self.clipboardText(r))
        case "desktop.clipboard.pull": self = .clipboardPull(seq: try r.uint32("seq"))
        case "desktop.clipboard":
            self = .clipboard(seq: r.has("seq") ? try r.uint32("seq") : nil, text: try Self.clipboardText(r))
        case "desktop.auth":
            let password = try r.string("password")
            guard password.utf8.count <= 1024 else { throw RdWireError("password: too long") }
            self = .auth(password: password)
        case "desktop.state":
            guard let state = DesktopState(rawValue: try r.string("state")) else { throw RdWireError("state") }
            self = .state(state, reason: r.optionalString("reason"))
        case "desktop.ended": self = .ended(reason: try r.string("reason"))
        case let other: throw RdWireError("desktop message \(other)")
        }
    }

    private static func mode(_ r: DesktopJSON) throws(RdWireError) -> DesktopMode {
        guard let mode = DesktopMode(rawValue: try r.string("mode")) else { throw RdWireError("mode") }
        return mode
    }

    private static func clipboardText(_ r: DesktopJSON) throws(RdWireError) -> String {
        let text = try r.string("text")
        guard text.utf8.count <= maxClipboardBytes else { throw RdWireError("clipboard text: too long") }
        return text
    }

    /// Wrapped as rd service control.
    public var rdControl: RdControlMessage {
        .service(service: Self.service, body: jsonValue)
    }
}

extension DesktopMessage: CustomStringConvertible {
    /// Never prints a password or clipboard text.
    public var description: String {
        switch self {
        case .auth: "desktop.auth(<redacted>)"
        case .clipboardPush(let seq, let text): "desktop.clipboard.push(\(seq), \(text.utf8.count) bytes)"
        case .clipboard(let seq, let text): "desktop.clipboard(\(seq.map(String.init) ?? "-"), \(text.utf8.count) bytes)"
        default: (try? jsonValue.canonicalData()).flatMap { String(data: $0, encoding: .utf8) } ?? "desktop message"
        }
    }
}
