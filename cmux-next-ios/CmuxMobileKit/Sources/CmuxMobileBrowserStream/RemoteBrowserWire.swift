import Foundation

/// The `cmux.rb/1` messages and input events a phone sends
/// (plans/cmux-next/remote-tab-protocol.md sections 4 and 6), as JSON.
public struct RemoteBrowserWire: Sendable {
    /// The phone's page size in CSS pixels and the scale frames are rendered at.
    public struct Screen: Sendable, Equatable {
        public var cssWidth: Int
        public var cssHeight: Int
        public var scale: Double

        public init(cssWidth: Int, cssHeight: Int, scale: Double) {
            self.cssWidth = cssWidth
            self.cssHeight = cssHeight
            self.scale = scale
        }

        /// The phone's view in points, rendered at the screen's scale capped
        /// at 2 (text stays sharp; 3x would add 2.25x the pixels to encode).
        public init(points: CGSize, screenScale: Double) {
            cssWidth = max(64, Int(points.width.rounded()))
            cssHeight = max(64, Int(points.height.rounded()))
            scale = min(max(screenScale, 1), 2)
        }

        var json: [String: Any] {
            ["css_width": cssWidth, "css_height": cssHeight, "scale": scale, "refresh_hz": 60, "color_space": "srgb"]
        }
    }

    public init() {}

    public func open(tab: String, viewer: String, screen: Screen) -> Data {
        encode(["t": "rb.open", "tab": tab, "profile": "default", "viewer": viewer, "screen": screen.json,
                "caps": ["codecs": ["h264"], "tile_codecs": [String](), "max_fps": 60]])
    }

    public func screen(seq: Int, _ screen: Screen) -> Data {
        encode(["t": "rb.screen", "seq": seq, "screen": screen.json])
    }

    public func navigate(_ url: String) -> Data { encode(["t": "rb.navigate", "url": url]) }

    /// `back`, `forward`, `reload`, `reload_no_cache`, `stop`.
    public func history(_ op: String) -> Data { encode(["t": "rb.history", "op": op]) }

    public func visibility(_ visible: Bool) -> Data { encode(["t": "rb.visibility", "visible": visible]) }

    /// A pointer event at CSS pixels (`move`, `down`, `up`).
    public func pointer(_ kind: String, x: Double, y: Double, buttons: Int, clickCount: Int = 1) -> Data {
        encode(["e": "pointer", "surface": 0, "kind": kind, "x": x, "y": y, "button": 0, "buttons": buttons,
                "click_count": clickCount, "modifiers": 0, "pointer_type": "mouse"])
    }

    /// A precise scroll at CSS pixels: `dy` > 0 moves the content down (a
    /// finger dragging down), as macOS natural scrolling reports it.
    public func wheel(x: Double, y: Double, dx: Double, dy: Double, phase: String, momentum: String) -> Data {
        encode(["e": "wheel", "surface": 0, "x": x, "y": y, "dx": dx, "dy": dy, "precise": true,
                "phase": phase, "momentum_phase": momentum, "modifiers": 0])
    }

    public func pinch(phase: String, scale: Double, x: Double, y: Double) -> Data {
        encode(["e": "pinch", "surface": 0, "phase": phase, "scale": scale, "x": x, "y": y])
    }

    /// Typed text (any length, any script) as an IME commit.
    public func commit(_ text: String) -> Data {
        encode(["e": "ime_commit", "surface": 0, "text": text, "replacement": NSNull()])
    }

    /// `cmux.rb/1` modifier bits (proto.rs `modifiers`).
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// A key with no text of its own (`Backspace`, `Enter`, `Tab`, arrows), or a
    /// shortcut: `editCommands` are the Mac's edit commands for it (`SelectAll`,
    /// `Copy`, ...), which Chromium runs as the Mac's own key bindings would.
    public func key(_ code: String, key: String, text: String = "", down: Bool, modifiers: Modifiers = [],
                    editCommands: [String] = []) -> Data {
        encode(["e": "key", "surface": 0, "down": down, "code": code, "key": key, "text": text, "unmodified_text": text,
                "modifiers": modifiers.rawValue, "repeat": false, "location": 0,
                "edit_commands": down ? editCommands.map { ["name": $0, "value": ""] } : [[String: String]]()])
    }

    /// A simulator's hardware button (`home`, `lock`; cmux-mobile-host `surface.rs`).
    public func button(_ name: String) -> Data {
        encode(["e": "button", "surface": 0, "button": name])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// What the host's `rb.page` says about the page.
public struct RemoteBrowserPage: Sendable, Equatable {
    public var url: String
    public var title: String
    public var loading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init?(json: [String: Any]) {
        guard json["t"] as? String == "rb.page" else { return nil }
        url = json["url"] as? String ?? ""
        title = json["title"] as? String ?? ""
        loading = json["loading"] as? Bool ?? false
        canGoBack = json["can_go_back"] as? Bool ?? false
        canGoForward = json["can_go_forward"] as? Bool ?? false
    }
}
