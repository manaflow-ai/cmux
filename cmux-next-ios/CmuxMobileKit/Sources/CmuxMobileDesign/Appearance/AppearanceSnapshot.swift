import Foundation

/// A Mac's `get-appearance` answer (PROTOCOL.md "Appearance", `appearance-v1`):
/// its theme for dark and light, accent, window style, tuning, terminal font,
/// chat bubble colors, group palette and background. Every field but
/// `revision` may be missing (an unset setting): the phone then uses its own
/// default. Decoding is lenient: a value of the wrong type is dropped, not the
/// snapshot.
public struct CmuxMobileAppearanceSnapshot: Codable, Equatable, Sendable {
    public var revision: Int
    public var theme: Theme?
    /// `appearance.accent`: `neutral`, `theme`, `red`, ...
    public var accent: String?
    /// `appearance.chromeStyle`: `default`, `two-tone`, `floating`, ...
    public var chromeStyle: String?
    /// `appearance.hue` (0.5 leaves the theme color unchanged) and
    /// `appearance.saturation` (1 leaves it unchanged): the backdrop tint's tuning.
    public var hue: Double?
    public var saturation: Double?
    /// `appearance.glassTransparency`: 0 theme opacity ... 1 clear glass.
    public var glassTransparency: Double?
    /// `appearance.sidebarSurface`: `same` or `separate`.
    public var sidebarSurface: String?
    public var terminal: Terminal?
    public var chat: Chat?
    public var groups: Groups?
    public var background: Background?

    public struct Theme: Codable, Equatable, Sendable {
        public var dark: Variant?
        public var light: Variant?
        public var followsSystem: Bool?

        public init(dark: Variant?, light: Variant?, followsSystem: Bool? = true) {
            self.dark = dark
            self.light = light
            self.followsSystem = followsSystem
        }
    }

    public struct Variant: Codable, Equatable, Sendable {
        public var name: String?
        public var input: Input

        public init(name: String?, input: Input) {
            self.name = name
            self.input = input
        }
    }

    /// `cmux-theme-tokens::ThemeInput` as JSON (`THEME_INPUT`).
    public struct Input: Codable, Equatable, Sendable {
        public var background: String
        public var foreground: String
        public var palette: [String]
        public var selectionBackground: String?
        public var selectionForeground: String?
        public var cursor: String?
        public var backgroundOpacity: Double
        public var backgroundBlur: Int
        public var accentColor: String?

        public init(background: String, foreground: String, palette: [String], selectionBackground: String? = nil,
                    selectionForeground: String? = nil, cursor: String? = nil, backgroundOpacity: Double = 1,
                    backgroundBlur: Int = 0, accentColor: String? = nil) {
            self.background = background
            self.foreground = foreground
            self.palette = palette
            self.selectionBackground = selectionBackground
            self.selectionForeground = selectionForeground
            self.cursor = cursor
            self.backgroundOpacity = backgroundOpacity
            self.backgroundBlur = backgroundBlur
            self.accentColor = accentColor
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            background = try c.decode(String.self, forKey: .background)
            foreground = try c.decode(String.self, forKey: .foreground)
            palette = (try? c.decodeIfPresent([String].self, forKey: .palette)) ?? []
            selectionBackground = try? c.decodeIfPresent(String.self, forKey: .selectionBackground)
            selectionForeground = try? c.decodeIfPresent(String.self, forKey: .selectionForeground)
            cursor = try? c.decodeIfPresent(String.self, forKey: .cursor)
            backgroundOpacity = (try? c.decodeIfPresent(Double.self, forKey: .backgroundOpacity)) ?? 1
            backgroundBlur = c.lenientInt(.backgroundBlur) ?? 0
            accentColor = try? c.decodeIfPresent(String.self, forKey: .accentColor)
        }
    }

    public struct Terminal: Codable, Equatable, Sendable {
        public var fontFamily: String?
        public var fontSize: Double?

        public init(fontFamily: String?, fontSize: Double? = nil) {
            self.fontFamily = fontFamily
            self.fontSize = fontSize
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fontFamily = try? c.decodeIfPresent(String.self, forKey: .fontFamily)
            fontSize = try? c.decodeIfPresent(Double.self, forKey: .fontSize)
        }
    }

    /// `home.bubbleColors.*`, each `#RRGGBB`.
    public struct Chat: Codable, Equatable, Sendable {
        public var sent: String?
        public var sentText: String?
        public var received: String?
        public var receivedText: String?

        public init(sent: String? = nil, sentText: String? = nil, received: String? = nil, receivedText: String? = nil) {
            self.sent = sent
            self.sentText = sentText
            self.received = received
            self.receivedText = receivedText
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sent = try? c.decodeIfPresent(String.self, forKey: .sent)
            sentText = try? c.decodeIfPresent(String.self, forKey: .sentText)
            received = try? c.decodeIfPresent(String.self, forKey: .received)
            receivedText = try? c.decodeIfPresent(String.self, forKey: .receivedText)
        }
    }

    /// `sidebar.groupPalette` (`glass`, `theme`, `grayscale`, `vibrant`,
    /// `gradient`, ...) and `sidebar.groupGradient` (`sunset`, `aurora`, ...).
    public struct Groups: Codable, Equatable, Sendable {
        public var palette: String?
        public var gradient: String?

        public init(palette: String?, gradient: String? = nil) {
            self.palette = palette
            self.gradient = gradient
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The setting is one name; a list (an older draft of the contract) means "unset".
            palette = try? c.decodeIfPresent(String.self, forKey: .palette)
            gradient = try? c.decodeIfPresent(String.self, forKey: .gradient)
        }
    }

    /// The Mac's shown backdrop as an image the phone fetches by hash
    /// (`appearance-asset`), with the Mac's opacity and blur for it.
    public struct Background: Codable, Equatable, Sendable {
        public var sha256: String
        public var bytes: Int
        public var width: Int
        public var height: Int
        public var luminance: Double
        public var opacity: Double
        public var blur: Double

        public init(sha256: String, bytes: Int, width: Int, height: Int, luminance: Double = 0.5, opacity: Double = 1, blur: Double = 0) {
            self.sha256 = sha256
            self.bytes = bytes
            self.width = width
            self.height = height
            self.luminance = luminance
            self.opacity = opacity
            self.blur = blur
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sha256 = try c.decode(String.self, forKey: .sha256).lowercased()
            bytes = c.lenientInt(.bytes) ?? 0
            width = c.lenientInt(.width) ?? 0
            height = c.lenientInt(.height) ?? 0
            luminance = (try? c.decodeIfPresent(Double.self, forKey: .luminance)) ?? 0.5
            opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1
            blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? 0
        }

        /// A 64-digit lowercase hex digest (anything else is never fetched or stored).
        public var hasValidHash: Bool {
            sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }

    public init(revision: Int, theme: Theme? = nil, accent: String? = nil, chromeStyle: String? = nil, hue: Double? = nil,
                saturation: Double? = nil, glassTransparency: Double? = nil, sidebarSurface: String? = nil,
                terminal: Terminal? = nil, chat: Chat? = nil, groups: Groups? = nil, background: Background? = nil) {
        self.revision = revision
        self.theme = theme
        self.accent = accent
        self.chromeStyle = chromeStyle
        self.hue = hue
        self.saturation = saturation
        self.glassTransparency = glassTransparency
        self.sidebarSurface = sidebarSurface
        self.terminal = terminal
        self.chat = chat
        self.groups = groups
        self.background = background
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = c.lenientInt(.revision) ?? 0
        theme = try? c.decodeIfPresent(Theme.self, forKey: .theme)
        accent = try? c.decodeIfPresent(String.self, forKey: .accent)
        chromeStyle = try? c.decodeIfPresent(String.self, forKey: .chromeStyle)
        hue = try? c.decodeIfPresent(Double.self, forKey: .hue)
        saturation = try? c.decodeIfPresent(Double.self, forKey: .saturation)
        glassTransparency = try? c.decodeIfPresent(Double.self, forKey: .glassTransparency)
        sidebarSurface = try? c.decodeIfPresent(String.self, forKey: .sidebarSurface)
        terminal = try? c.decodeIfPresent(Terminal.self, forKey: .terminal)
        chat = try? c.decodeIfPresent(Chat.self, forKey: .chat)
        groups = try? c.decodeIfPresent(Groups.self, forKey: .groups)
        background = try? c.decodeIfPresent(Background.self, forKey: .background)
    }

    /// The snapshot in a `get-appearance` reply (`{"ok":true,"data":{"appearance":{…}}}`,
    /// or `{"appearance":{…}}`, or the bare object); nil when there is none.
    public static func parse(reply: Data) -> CmuxMobileAppearanceSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        let data = object["data"] as? [String: Any] ?? object
        let appearance = data["appearance"] as? [String: Any] ?? data
        guard appearance["revision"] != nil,
              let bytes = try? JSONSerialization.data(withJSONObject: appearance) else { return nil }
        return decode(bytes)
    }

    /// A stored or wire snapshot object (snake_case keys).
    public static func decode(_ data: Data) -> CmuxMobileAppearanceSnapshot? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(CmuxMobileAppearanceSnapshot.self, from: data)
    }

    /// The snapshot as stored on disk (the wire's snake_case keys).
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

extension KeyedDecodingContainer {
    /// An integer sent as a JSON integer or a whole double.
    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int(value) }
        return nil
    }
}
