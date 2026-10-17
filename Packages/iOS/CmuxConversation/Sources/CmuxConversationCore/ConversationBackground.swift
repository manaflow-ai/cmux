import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A conversation background, as iOS 26 and macOS 26 Messages share it with
/// everyone in the conversation: a color or gradient, a photo, or one of the
/// dynamic (animated) backgrounds. ChatKit stores the background's luminance
/// with it (`transcriptBackgroundLuminosity`) and derives the transcript's
/// light or dark style from that, so every device renders the same contrast
/// without sampling the image itself.
public struct ConversationBackground: Sendable, Hashable {
    /// The picker's categories (ChatKit `BACKGROUND_TYPE_*`), Playground aside.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case color
        case photo
        case sky
        case water
        case aurora
        case glitter

        /// Sky, Water, Aurora and Glitter animate; Reduce Motion holds them still.
        public var isDynamic: Bool {
            switch self {
            case .color, .photo: return false
            case .sky, .water, .aurora, .glitter: return true
            }
        }
    }

    public struct Photo: Sendable, Hashable {
        /// Remote location. Nil while a photo picked here is uploading.
        public var url: URL?
        public var width: Int
        public var height: Int
        /// Bytes picked on this device, so the background shows before upload.
        public var localData: Data?

        public init(url: URL?, width: Int, height: Int, localData: Data? = nil) {
            self.url = url
            self.width = width
            self.height = height
            self.localData = localData
        }
    }

    /// Changes on every set, so a renderer can tell a new background from a
    /// re-delivery of the current one. `local:` while unconfirmed.
    public var id: String
    public var kind: Kind
    /// The look, top to bottom, as `#RRGGBB`: one color is a solid fill, more
    /// make a gradient. Dynamic backgrounds tint their animation with them.
    public var colors: [String]
    /// The preset the look came from (`ConversationBackgroundLook.id`), if any.
    public var look: String?
    public var photo: Photo?
    /// Mean relative luminance of the background, 0 (black) to 1 (white).
    public var luminance: Double
    /// Who set it.
    public var setBy: String?

    public init(
        id: String,
        kind: Kind,
        colors: [String] = [],
        look: String? = nil,
        photo: Photo? = nil,
        luminance: Double,
        setBy: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.colors = colors
        self.look = look
        self.photo = photo
        self.luminance = min(1, max(0, luminance))
        self.setBy = setBy
    }

    // MARK: Contrast

    /// Below this luminance the transcript switches to its dark style (light
    /// timestamps, sender names and system text). It is where white and black
    /// text have equal WCAG contrast against the background,
    /// sqrt(1.05 * 0.05) - 0.05. ChatKit's own threshold
    /// (`lightInterfacePosterContentLuminanceThreshold`) was not measured.
    public static let darkContentThreshold: Double = (1.05 * 0.05).squareRoot() - 0.05

    /// The transcript over this background renders in the dark style.
    public var prefersDarkContent: Bool { luminance < Self.darkContentThreshold }

    /// WCAG relative luminance of `#RRGGBB` (nil when malformed).
    public static func relativeLuminance(hex: String) -> Double? {
        guard let (r, g, b) = rgb(hex: hex) else { return nil }
        return relativeLuminance(r: r, g: g, b: b)
    }

    /// WCAG relative luminance of sRGB components in 0...1.
    public static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Mean luminance of a look's colors (a gradient covers each stop evenly).
    public static func luminance(colors: [String]) -> Double? {
        let values = colors.compactMap { relativeLuminance(hex: $0) }
        guard !values.isEmpty, values.count == colors.count else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Luminance of `colors` as `kind` draws them: gradients (Color, Sky,
    /// Water) cover each stop evenly; Aurora and Glitter fill the screen
    /// with their first (base) color and only accent it with the others.
    public static func luminance(kind: Kind, colors: [String]) -> Double? {
        switch kind {
        case .color, .photo, .sky, .water:
            return luminance(colors: colors)
        case .aurora, .glitter:
            guard let base = colors.first.flatMap(relativeLuminance(hex:)) else { return nil }
            guard let accents = luminance(colors: Array(colors.dropFirst())), colors.count > 1 else { return base }
            return 0.85 * base + 0.15 * accents
        }
    }

    /// sRGB components in 0...1 of `#RRGGBB`.
    public static func rgb(hex: String) -> (Double, Double, Double)? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// `#RRGGBB` for sRGB components in 0...1.
    public static func hex(r: Double, g: Double, b: Double) -> String {
        func byte(_ c: Double) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    #if canImport(CoreGraphics)
    /// Mean relative luminance of an image, sampled at 16 x 16.
    public static func luminance(of image: CGImage) -> Double? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += relativeLuminance(
                r: Double(pixels[index]) / 255,
                g: Double(pixels[index + 1]) / 255,
                b: Double(pixels[index + 2]) / 255
            )
        }
        return total / Double(side * side)
    }
    #endif
}

/// What a participant picks: everything but the server's identity. A photo
/// travels as an uploaded attachment id.
public struct ConversationBackgroundDraft: Sendable, Hashable {
    public var kind: ConversationBackground.Kind
    public var colors: [String]
    public var look: String?
    /// `photo` only: the uploaded image.
    public var attachmentID: String?
    /// Nil lets the service derive it from `colors`; a photo must carry it.
    public var luminance: Double?

    public init(kind: ConversationBackground.Kind, colors: [String] = [], look: String? = nil, attachmentID: String? = nil, luminance: Double? = nil) {
        self.kind = kind
        self.colors = colors
        self.look = look
        self.attachmentID = attachmentID
        self.luminance = luminance
    }

    public init(look: ConversationBackgroundLook) {
        self.init(kind: look.kind, colors: look.colors, look: look.id, luminance: look.luminance)
    }

    /// A solid color from a color picker.
    public static func color(_ hex: String) -> ConversationBackgroundDraft {
        ConversationBackgroundDraft(kind: .color, colors: [hex], luminance: ConversationBackground.luminance(colors: [hex]))
    }

    /// The background this draft shows while the service confirms it.
    public func optimisticBackground(id: String, setBy: String?, photo: ConversationBackground.Photo? = nil) -> ConversationBackground {
        ConversationBackground(
            id: id,
            kind: kind,
            colors: colors,
            look: look,
            photo: photo,
            luminance: luminance ?? ConversationBackground.luminance(kind: kind, colors: colors) ?? 0.5,
            setBy: setBy
        )
    }
}

/// A preset in the background picker. Names reuse the looks Messages'
/// background poster extensions ship (Dawn, Dusk, Deep Sea, Plum, ...);
/// the colors are approximations (not sampled from Messages).
public struct ConversationBackgroundLook: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ConversationBackground.Kind
    public var colors: [String]

    public init(id: String, kind: ConversationBackground.Kind, colors: [String]) {
        self.id = id
        self.kind = kind
        self.colors = colors
    }

    public var luminance: Double { ConversationBackground.luminance(kind: kind, colors: colors) ?? 0.5 }

    /// The preset for `id`, if it is one.
    public static func named(_ id: String?) -> ConversationBackgroundLook? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    public static func looks(for kind: ConversationBackground.Kind) -> [ConversationBackgroundLook] {
        all.filter { $0.kind == kind }
    }

    public static let all: [ConversationBackgroundLook] = [
        // Color: gradients, light to dark.
        .init(id: "color.ice", kind: .color, colors: ["#E8F3FF", "#B9D8F5"]),
        .init(id: "color.bubblegum", kind: .color, colors: ["#FFD1E8", "#F78FC4"]),
        .init(id: "color.mango", kind: .color, colors: ["#FFE29A", "#FFA94D"]),
        .init(id: "color.greenApple", kind: .color, colors: ["#D9F99D", "#7BD389"]),
        .init(id: "color.silver", kind: .color, colors: ["#F2F2F5", "#C7C7CF"]),
        .init(id: "color.tangerine", kind: .color, colors: ["#FFB36B", "#F0612E"]),
        .init(id: "color.cherry", kind: .color, colors: ["#F2546B", "#9E1631"]),
        .init(id: "color.magenta", kind: .color, colors: ["#E64AC0", "#7A1D86"]),
        .init(id: "color.plum", kind: .color, colors: ["#8E4FB8", "#3B1859"]),
        .init(id: "color.deepSea", kind: .color, colors: ["#1E5BA8", "#0A1F4D"]),
        .init(id: "color.stone", kind: .color, colors: ["#8A8A8F", "#4A4A4F"]),
        .init(id: "color.carbon", kind: .color, colors: ["#3A3A3C", "#0E0E10"]),
        // Sky: clouds drifting over a sky gradient.
        .init(id: "sky.clear", kind: .sky, colors: ["#5AA9F2", "#A8D4FA", "#E3F1FD"]),
        .init(id: "sky.sunrise", kind: .sky, colors: ["#F7B58A", "#F9D9B5", "#BFD8F2"]),
        .init(id: "sky.sunset", kind: .sky, colors: ["#3B4C8C", "#C46A7A", "#F5A35C"]),
        .init(id: "sky.dusk", kind: .sky, colors: ["#141B3D", "#3A3470", "#7A4F86"]),
        // Water: slow swells.
        .init(id: "water.light", kind: .water, colors: ["#9EE2F0", "#3FB8D9", "#1A86B8"]),
        .init(id: "water.deepSea", kind: .water, colors: ["#0F4C75", "#082A47", "#03121F"]),
        // Aurora: ribbons over a night sky.
        .init(id: "aurora.green", kind: .aurora, colors: ["#030914", "#1FD89A", "#5B6CF2"]),
        .init(id: "aurora.purple", kind: .aurora, colors: ["#08051A", "#B04CF5", "#F25B9E"]),
        // Glitter: sparkles over a deep tint.
        .init(id: "glitter.pink", kind: .glitter, colors: ["#3A0C2A", "#F06BB8", "#FFE3F3"]),
        .init(id: "glitter.gold", kind: .glitter, colors: ["#241A05", "#E8B64A", "#FFF4D6"]),
        .init(id: "glitter.silver", kind: .glitter, colors: ["#15171C", "#B8C0CC", "#FFFFFF"]),
    ]
}

/// Shared copy for backgrounds, so iOS and macOS read the same.
public enum ConversationBackgroundStrings {
    public static var editBackground: String {
        String(localized: "conversation.background.edit", defaultValue: "Edit Background", bundle: .module)
    }
    public static var backgrounds: String {
        String(localized: "conversation.background.tab", defaultValue: "Backgrounds", bundle: .module)
    }
    public static var set: String {
        String(localized: "conversation.background.set", defaultValue: "Set", bundle: .module)
    }
    public static var backgroundColor: String {
        String(localized: "conversation.background.color", defaultValue: "Background Color", bundle: .module)
    }
    public static var none: String {
        String(localized: "conversation.background.type.none", defaultValue: "None", bundle: .module)
    }

    public static func name(_ kind: ConversationBackground.Kind) -> String {
        switch kind {
        case .color: return String(localized: "conversation.background.type.color", defaultValue: "Color", bundle: .module)
        case .photo: return String(localized: "conversation.background.type.photo", defaultValue: "Photo", bundle: .module)
        case .sky: return String(localized: "conversation.background.type.sky", defaultValue: "Sky", bundle: .module)
        case .water: return String(localized: "conversation.background.type.water", defaultValue: "Water", bundle: .module)
        case .aurora: return String(localized: "conversation.background.type.aurora", defaultValue: "Aurora", bundle: .module)
        case .glitter: return String(localized: "conversation.background.type.glitter", defaultValue: "Glitter", bundle: .module)
        }
    }

    /// The preset's name, as Messages' poster extensions call it.
    public static func name(_ look: ConversationBackgroundLook) -> String {
        switch look.id {
        case "color.ice": return String(localized: "conversation.background.look.ice", defaultValue: "Ice", bundle: .module)
        case "color.bubblegum": return String(localized: "conversation.background.look.bubblegum", defaultValue: "Bubblegum", bundle: .module)
        case "color.mango": return String(localized: "conversation.background.look.mango", defaultValue: "Mango", bundle: .module)
        case "color.greenApple": return String(localized: "conversation.background.look.greenApple", defaultValue: "Green Apple", bundle: .module)
        case "color.silver", "glitter.silver": return String(localized: "conversation.background.look.silver", defaultValue: "Silver", bundle: .module)
        case "color.tangerine": return String(localized: "conversation.background.look.tangerine", defaultValue: "Tangerine", bundle: .module)
        case "color.cherry": return String(localized: "conversation.background.look.cherry", defaultValue: "Cherry", bundle: .module)
        case "color.magenta": return String(localized: "conversation.background.look.magenta", defaultValue: "Magenta", bundle: .module)
        case "color.plum": return String(localized: "conversation.background.look.plum", defaultValue: "Plum", bundle: .module)
        case "color.deepSea", "water.deepSea": return String(localized: "conversation.background.look.deepSea", defaultValue: "Deep Sea", bundle: .module)
        case "color.stone": return String(localized: "conversation.background.look.stone", defaultValue: "Stone", bundle: .module)
        case "color.carbon": return String(localized: "conversation.background.look.carbon", defaultValue: "Carbon", bundle: .module)
        case "sky.clear": return String(localized: "conversation.background.look.clear", defaultValue: "Clear", bundle: .module)
        case "sky.sunrise": return String(localized: "conversation.background.look.sunrise", defaultValue: "Sunrise", bundle: .module)
        case "sky.sunset": return String(localized: "conversation.background.look.sunset", defaultValue: "Sunset", bundle: .module)
        case "sky.dusk": return String(localized: "conversation.background.look.dusk", defaultValue: "Dusk", bundle: .module)
        case "water.light": return String(localized: "conversation.background.look.light", defaultValue: "Light", bundle: .module)
        case "aurora.green": return String(localized: "conversation.background.look.green", defaultValue: "Green", bundle: .module)
        case "aurora.purple": return String(localized: "conversation.background.look.purple", defaultValue: "Purple", bundle: .module)
        case "glitter.pink": return String(localized: "conversation.background.look.pink", defaultValue: "Pink", bundle: .module)
        case "glitter.gold": return String(localized: "conversation.background.look.gold", defaultValue: "Gold", bundle: .module)
        default: return name(look.kind)
        }
    }
}
