import Foundation

// Browser surfaces over the cmux-tui control protocol (protocol v12 with
// `browser-pointer-frame-guard-v1`; cmux-tui/docs/protocol.md "Attach
// Surface", spec/events.md `browser-state`/`frame`). A browser tab exists
// only when the server runs a `cmux-browser` provider; cmux-tui never
// launches Chrome itself.

/// Lifecycle of a browser surface's CDP runtime.
public enum CmuxTUIBrowserStatus: String, Sendable, Equatable {
    case starting
    case live
    case failed
}

/// One browser tab placed in a workspace (`list-workspaces`, `kind:"browser"`).
public struct CmuxTUIBrowserTab: Sendable, Equatable, Identifiable {
    public var id: Int { surface }
    /// Numeric surface id used by attach and browser commands; valid for this
    /// daemon generation only.
    public var surface: Int
    public var pane: Int
    public var screen: Int
    /// Stable browser content id (`content_resource_id`). Prefer it for storage.
    public var resourceID: String?
    public var url: String?
    public var title: String
    public var status: CmuxTUIBrowserStatus?
    public var error: String?
    public var framesStalled: Bool
    public var cols: Int?
    public var rows: Int?
    public var dead: Bool
}

/// One PNG bitmap of a browser surface.
public struct CmuxTUIBrowserFrame: Sendable, Equatable {
    /// Image sequence; a newer value supersedes older pixels. This is not the
    /// pointer token (see ``pointerFrameSeq``).
    public var seq: UInt64
    /// Page viewport in CSS pixels. Pointer coordinates use this space.
    public var width: Int
    public var height: Int
    /// Encoded bitmap size in pixels (equals ``width``/``height`` unless the
    /// server captures at a different scale).
    public var imageWidth: Int
    public var imageHeight: Int
    /// Base64 PNG exactly as received, so consumers that re-wrap it (the
    /// phone's frame decoder takes base64) avoid a decode/encode round trip.
    public var base64PNG: String
    /// Status coupled with these pixels. `nil` on the frame embedded in the
    /// initial `browser-state` (the enclosing state carries it).
    public var status: CmuxTUIBrowserStatus?
    public var error: String?
    /// Pointer admission range coupled with these pixels (`nil` = input blocked).
    public var pointerFrameFloorSeq: UInt64?
    public var pointerFrameSeq: UInt64?

    /// The decoded PNG bytes.
    public var png: Data { Data(base64Encoded: base64PNG) ?? Data() }
}

/// A `browser-state` event: page metadata plus pointer authority.
public struct CmuxTUIBrowserState: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var url: String
    public var title: String
    public var status: CmuxTUIBrowserStatus
    /// Raw browser-runtime text; not stable or safe to parse.
    public var error: String?
    public var framesStalled: Bool
    public var pointerFrameFloorSeq: UInt64?
    public var pointerFrameSeq: UInt64?
    /// The latest bitmap, present only on the first state of an attach.
    public var frame: CmuxTUIBrowserFrame?
}

/// One event of a browser attach stream, in server order.
public enum CmuxTUIBrowserEvent: Sendable, Equatable {
    case state(CmuxTUIBrowserState)
    case frame(CmuxTUIBrowserFrame)
    /// The server ended the stream (the tab closed or its tap stopped).
    case ended
    /// The transport closed; re-list before reattaching.
    case disconnected
}

/// Browser navigation commands that take only a surface.
public enum CmuxTUIBrowserNavigation: String, Sendable {
    case back = "browser-back"
    case forward = "browser-forward"
    case reload = "browser-reload"
}

/// Mouse phases for `browser-mouse-guarded`.
public enum CmuxTUIBrowserMouseKind: String, Sendable {
    case down
    case up
    case move
}

/// A CDP key press (`browser-key-press`).
public struct CmuxTUIBrowserKey: Sendable, Equatable {
    public var key: String
    public var code: String
    public var windowsVirtualKeyCode: Int
    /// CDP modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
    public var modifiers: Int
    public var text: String?

    public init(key: String, code: String, windowsVirtualKeyCode: Int, modifiers: Int = 0, text: String? = nil) {
        self.key = key
        self.code = code
        self.windowsVirtualKeyCode = windowsVirtualKeyCode
        self.modifiers = modifiers
        self.text = text
    }

    /// Maps a phone key token (`return`, `delete`, `tab`, `escape`, arrows,
    /// `home`, `end`, `pageup`, `pagedown`) and modifier names (`shift`,
    /// `control`/`ctrl`, `option`/`alt`, `command`/`cmd`/`meta`) to CDP.
    public static func named(_ token: String, modifiers names: [String] = []) -> CmuxTUIBrowserKey? {
        var bits = 0
        for name in names {
            switch name.lowercased() {
            case "option", "alt": bits |= 1
            case "control", "ctrl": bits |= 2
            case "command", "cmd", "meta": bits |= 4
            case "shift": bits |= 8
            default: break
            }
        }
        let base: CmuxTUIBrowserKey
        switch token.lowercased() {
        case "return", "enter": base = .init(key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r")
        case "delete", "backspace": base = .init(key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8)
        case "forwarddelete": base = .init(key: "Delete", code: "Delete", windowsVirtualKeyCode: 46)
        case "tab": base = .init(key: "Tab", code: "Tab", windowsVirtualKeyCode: 9)
        case "escape", "esc": base = .init(key: "Escape", code: "Escape", windowsVirtualKeyCode: 27)
        case "up": base = .init(key: "ArrowUp", code: "ArrowUp", windowsVirtualKeyCode: 38)
        case "down": base = .init(key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40)
        case "left": base = .init(key: "ArrowLeft", code: "ArrowLeft", windowsVirtualKeyCode: 37)
        case "right": base = .init(key: "ArrowRight", code: "ArrowRight", windowsVirtualKeyCode: 39)
        case "home": base = .init(key: "Home", code: "Home", windowsVirtualKeyCode: 36)
        case "end": base = .init(key: "End", code: "End", windowsVirtualKeyCode: 35)
        case "pageup": base = .init(key: "PageUp", code: "PageUp", windowsVirtualKeyCode: 33)
        case "pagedown": base = .init(key: "PageDown", code: "PageDown", windowsVirtualKeyCode: 34)
        default: return nil
        }
        var key = base
        key.modifiers = bits
        // A modified Enter/Tab is a shortcut, not text.
        if bits & ~8 != 0 { key.text = nil }
        return key
    }
}

/// Client-side pointer authority for one browser attachment, mirroring the
/// bundled remote TUI (`crates/cmux-tui/src/session/remote.rs`): new
/// authority arrives only together with its pixels, state-only updates can
/// keep or revoke it, and pointer input needs a presented token in range.
public struct CmuxTUIBrowserPointerGuard: Sendable, Equatable {
    public private(set) var status: CmuxTUIBrowserStatus = .starting
    public private(set) var floor: UInt64?
    public private(set) var latest: UInt64?
    /// The token this client told the server it presented.
    public private(set) var presented: UInt64?

    public init() {}

    public mutating func apply(_ state: CmuxTUIBrowserState) {
        status = state.status
        let advertised = status == .live ? Self.range(floor: state.pointerFrameFloorSeq, latest: state.pointerFrameSeq) : nil
        // State-only messages may retain existing authority or revoke it;
        // new authority must arrive atomically with its pixels.
        let sameRange = advertised?.0 == floor && advertised?.1 == latest
        let accepted = state.frame != nil || sameRange ? advertised : nil
        (floor, latest) = (accepted?.0, accepted?.1)
        retainPresented()
    }

    public mutating func apply(_ frame: CmuxTUIBrowserFrame) {
        if let status = frame.status { self.status = status }
        let range = frame.status == .live ? Self.range(floor: frame.pointerFrameFloorSeq, latest: frame.pointerFrameSeq) : nil
        (floor, latest) = (range?.0, range?.1)
        retainPresented()
    }

    /// Records that `token` is on screen. Returns `true` when the server
    /// should be told (`browser-frame-presented`).
    public mutating func acknowledge(_ token: UInt64) -> Bool {
        guard status == .live, inRange(token) else { return false }
        if let presented, presented >= token { return false }
        presented = token
        return true
    }

    /// The token to attach to pointer input, or `nil` while input is blocked.
    public var pointerToken: UInt64? {
        guard status == .live, let presented, inRange(presented) else { return nil }
        return presented
    }

    private func inRange(_ token: UInt64) -> Bool {
        guard let floor, let latest else { return false }
        return (floor...latest).contains(token)
    }

    private mutating func retainPresented() {
        if let presented, !inRange(presented) { self.presented = nil }
    }

    private static func range(floor: UInt64?, latest: UInt64?) -> (UInt64, UInt64)? {
        guard let latest else { return nil }
        let floor = floor ?? latest
        return floor <= latest ? (floor, latest) : nil
    }
}

// MARK: - Wire

struct CmuxTUIBrowserEventWire: Decodable {
    struct Frame: Decodable {
        var seq: UInt64
        var width: Int?
        var height: Int?
        var image_width: Int?
        var image_height: Int?
        var data: String
    }
    var event: String
    var surface: Int?
    var cols: Int?
    var rows: Int?
    var url: String?
    var title: String?
    var status: String?
    var error: String?
    var frames_stalled: Bool?
    var pointer_frame_floor_seq: UInt64?
    var pointer_frame_seq: UInt64?
    var frame: Frame?
    // Top-level frame fields (`frame` event).
    var seq: UInt64?
    var width: Int?
    var height: Int?
    var image_width: Int?
    var image_height: Int?
    var data: String?
}

extension CmuxTUIBrowserEventWire {
    /// Decodes a `browser-state` or `frame` line; `nil` when the line is not
    /// JSON of this shape.
    init?(line: Data) {
        guard let wire = try? JSONDecoder().decode(CmuxTUIBrowserEventWire.self, from: line) else { return nil }
        self = wire
    }

    /// The surface and browser event this line carries, or `nil` for any
    /// other event or an incomplete one.
    var surfaceEvent: (surface: Int, event: CmuxTUIBrowserEvent)? {
        let wire = self
        guard let surface = wire.surface else { return nil }
        switch wire.event {
        case "browser-state":
            let status = wire.status.flatMap(CmuxTUIBrowserStatus.init(rawValue:)) ?? .starting
            let frame = wire.frame.map { nested in
                CmuxTUIBrowserFrame(
                    seq: nested.seq,
                    width: nested.width,
                    height: nested.height,
                    imageWidth: nested.image_width,
                    imageHeight: nested.image_height,
                    data: nested.data,
                    status: nil,
                    error: nil,
                    floor: wire.pointer_frame_floor_seq,
                    latest: wire.pointer_frame_seq
                )
            }
            return (surface, .state(CmuxTUIBrowserState(
                cols: wire.cols ?? 0,
                rows: wire.rows ?? 0,
                url: wire.url ?? "",
                title: wire.title ?? "",
                status: status,
                error: wire.error,
                framesStalled: wire.frames_stalled ?? false,
                pointerFrameFloorSeq: wire.pointer_frame_floor_seq,
                pointerFrameSeq: wire.pointer_frame_seq,
                frame: frame
            )))
        case "frame":
            guard let seq = wire.seq, let data = wire.data else { return nil }
            return (surface, .frame(CmuxTUIBrowserFrame(
                seq: seq,
                width: wire.width,
                height: wire.height,
                imageWidth: wire.image_width,
                imageHeight: wire.image_height,
                data: data,
                status: wire.status.flatMap(CmuxTUIBrowserStatus.init(rawValue:)),
                error: wire.error,
                floor: wire.pointer_frame_floor_seq,
                latest: wire.pointer_frame_seq
            )))
        default:
            return nil
        }
    }
}

extension CmuxTUIBrowserFrame {
    fileprivate init(
        seq: UInt64,
        width: Int?,
        height: Int?,
        imageWidth: Int?,
        imageHeight: Int?,
        data: String,
        status: CmuxTUIBrowserStatus?,
        error: String?,
        floor: UInt64?,
        latest: UInt64?
    ) {
        let width = width ?? 0
        let height = height ?? 0
        self.init(
            seq: seq,
            width: width,
            height: height,
            imageWidth: imageWidth.flatMap { $0 > 0 ? $0 : nil } ?? width,
            imageHeight: imageHeight.flatMap { $0 > 0 ? $0 : nil } ?? height,
            base64PNG: data,
            status: status,
            error: error,
            pointerFrameFloorSeq: floor,
            pointerFrameSeq: latest
        )
    }
}

struct CmuxTUICellPixelsWire: Decodable {
    var width_px: Int
    var height_px: Int
}
