public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// The reducer's answer to one input (`{"effects", "note", "reject"}`).
public nonisolated struct RbClientOutcome: Sendable, Equatable, Decodable {
    public var effects: [RbClientEffect]
    /// Why an input changed nothing (`stale_answer`, `unhandled`, ...).
    public var note: String?
    /// Why an input was refused as a protocol error.
    public var reject: String?
}

/// One effect for the pane, in order (`ClientEffect`, tag `effect`).
public nonisolated enum RbClientEffect: Sendable, Equatable, Decodable {
    /// Send this `rb.*` body to the host.
    case send(RemoteRdJSON)
    case showMenu(token: UInt64, menu: RbMenu)
    case closeMenu(token: UInt64)
    case showDialog(token: UInt64, dialog: RbDialog)
    case closeDialog(token: UInt64)
    /// A CSS cursor name (`pointer`, `text`, ...) or `custom` with an image hash.
    case setCursor(kind: String, hash: String?)
    case page(url: String, title: String, loading: Bool, canGoBack: Bool, canGoForward: Bool)
    case screenApplied(pixelWidth: Int, pixelHeight: Int, scale: Double)
    /// `idle`, `opening`, `live`, `paused`, `crashed`, `closed`.
    case session(state: String)
    case keyUnhandled(inputSeq: UInt32)
    case openTab(request: UInt64, url: String, disposition: String, userGesture: Bool)
    /// An effect a later step handles (`text_input`, ...).
    case other(String)

    private enum Keys: String, CodingKey {
        case effect, message, token, menu, dialog, cursor, url, title, loading, scale, state, request, disposition
        case canGoBack = "can_go_back", canGoForward = "can_go_forward"
        case pixelWidth = "pixel_width", pixelHeight = "pixel_height"
        case inputSeq = "input_seq", userGesture = "user_gesture"
    }

    private struct Cursor: Decodable {
        var kind: String
        var hash: String?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let effect = try c.decode(String.self, forKey: .effect)
        switch effect {
        case "send": self = .send(try c.decode(RemoteRdJSON.self, forKey: .message))
        case "show_menu": self = .showMenu(token: try c.decode(UInt64.self, forKey: .token), menu: try c.decode(RbMenu.self, forKey: .menu))
        case "close_menu": self = .closeMenu(token: try c.decode(UInt64.self, forKey: .token))
        case "show_dialog":
            self = .showDialog(token: try c.decode(UInt64.self, forKey: .token), dialog: try c.decode(RbDialog.self, forKey: .dialog))
        case "close_dialog": self = .closeDialog(token: try c.decode(UInt64.self, forKey: .token))
        case "set_cursor":
            let cursor = try c.decode(Cursor.self, forKey: .cursor)
            self = .setCursor(kind: cursor.kind, hash: cursor.hash)
        case "page":
            self = .page(
                url: try c.decode(String.self, forKey: .url), title: try c.decode(String.self, forKey: .title),
                loading: try c.decode(Bool.self, forKey: .loading), canGoBack: try c.decode(Bool.self, forKey: .canGoBack),
                canGoForward: try c.decode(Bool.self, forKey: .canGoForward))
        case "screen_applied":
            self = .screenApplied(
                pixelWidth: try c.decode(Int.self, forKey: .pixelWidth), pixelHeight: try c.decode(Int.self, forKey: .pixelHeight),
                scale: try c.decode(Double.self, forKey: .scale))
        case "session": self = .session(state: try c.decode(String.self, forKey: .state))
        case "key_unhandled": self = .keyUnhandled(inputSeq: try c.decode(UInt32.self, forKey: .inputSeq))
        case "open_tab":
            self = .openTab(
                request: try c.decode(UInt64.self, forKey: .request), url: try c.decode(String.self, forKey: .url),
                disposition: try c.decode(String.self, forKey: .disposition), userGesture: try c.decode(Bool.self, forKey: .userGesture))
        default: self = .other(effect)
        }
    }
}
#endif
