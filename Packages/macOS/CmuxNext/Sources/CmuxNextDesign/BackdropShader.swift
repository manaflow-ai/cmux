public import Foundation

/// A living wallpaper: a Metal shader that draws the window's backdrop every frame and answers the
/// mouse (ask-722b8b001e, Leo: "we have static wallpapers, we have moving wallpapers... now we have
/// wallpapers that run under code! that you can interact with with your mouse!").
///
/// Each case is one fragment function in ``BackdropShaderSource``. The pointer stirs, bends or
/// pushes what is drawn near it, and a click sends a ring out from where it lands. Under Reduce
/// Motion, Low Power Mode or a hot Mac the frame holds (``BackdropShaderView``). A still of each,
/// for light and dark, is rendered once to a file (``posterURL(dark:)``): the picker's thumbnail,
/// the poster under the live layer, the iPhone's copy and what a page's glass lenses.
public nonisolated enum BackdropShader: String, CaseIterable, Sendable {
    /// Ink currents that swirl around the pointer.
    case currents
    /// A still pond: the pointer leaves a wake and a click drops a ripple.
    case ripples
    /// Curtains of light that lean toward the pointer.
    case aurora
    /// A grid of dots the pointer pushes aside, like iron filings near a magnet.
    case field
    /// Frutiger Aero: glass bubbles rising through a glossy sky; they drift aside from the pointer.
    case aero
    /// Cherry-blossom petals drifting through a dusk sky; the pointer parts them like a breath of wind.
    case sakura
    /// Ink blooming slowly in water; a click drops more ink.
    case sumi
    /// Light on a pond floor with koi swimming under it; they swim clear of the pointer.
    case koi
    /// Snow drifting down over dark ridges; the pointer sends a gust through it.
    case snowfall
    /// The warm bokeh of paper lanterns rising slowly; those near the pointer glow.
    case lanterns
    /// Rain on a window at night, city lights soft behind the glass.
    case rain
    /// Block Matrix: a fine matrix of faint dots lit in blocks; a glow follows the pointer.
    case matrix

    /// The prefix of a persisted id (`shader:currents`).
    public static let idPrefix = "shader:"

    /// The value `cmux.json` keeps.
    public var id: String { Self.idPrefix + rawValue }

    /// The shader a persisted id names, nil for any other id.
    public init?(id: String) {
        guard id.hasPrefix(Self.idPrefix) else { return nil }
        self.init(rawValue: String(id.dropFirst(Self.idPrefix.count)))
    }

    /// The name shown under the thumbnail.
    public var title: String {
        switch self {
        case .currents: String(localized: "backdrop.shader.currents", defaultValue: "Currents", bundle: .localizedModule)
        case .ripples: String(localized: "backdrop.shader.ripples", defaultValue: "Ripples", bundle: .localizedModule)
        case .aurora: String(localized: "backdrop.shader.aurora", defaultValue: "Aurora", bundle: .localizedModule)
        case .field: String(localized: "backdrop.shader.field", defaultValue: "Dot Field", bundle: .localizedModule)
        case .aero: String(localized: "backdrop.shader.aero", defaultValue: "Aero", bundle: .localizedModule)
        case .sakura: String(localized: "backdrop.shader.sakura", defaultValue: "Sakura", bundle: .localizedModule)
        case .sumi: String(localized: "backdrop.shader.sumi", defaultValue: "Sumi", bundle: .localizedModule)
        case .koi: String(localized: "backdrop.shader.koi", defaultValue: "Koi", bundle: .localizedModule)
        case .snowfall: String(localized: "backdrop.shader.snowfall", defaultValue: "Snowfall", bundle: .localizedModule)
        case .lanterns: String(localized: "backdrop.shader.lanterns", defaultValue: "Lanterns", bundle: .localizedModule)
        case .rain: String(localized: "backdrop.shader.rain", defaultValue: "Rain", bundle: .localizedModule)
        case .matrix: String(localized: "backdrop.shader.matrix", defaultValue: "Block Matrix", bundle: .localizedModule)
        }
    }

    /// The line under the title: what the pointer does to it.
    public var attribution: String {
        switch self {
        case .currents:
            String(localized: "backdrop.shader.currents.attribution", defaultValue: "Live · the pointer stirs the ink", bundle: .localizedModule)
        case .ripples:
            String(localized: "backdrop.shader.ripples.attribution", defaultValue: "Live · click to drop a ripple", bundle: .localizedModule)
        case .aurora:
            String(localized: "backdrop.shader.aurora.attribution", defaultValue: "Live · the light leans toward the pointer", bundle: .localizedModule)
        case .field:
            String(localized: "backdrop.shader.field.attribution", defaultValue: "Live · the pointer pushes the dots aside", bundle: .localizedModule)
        case .aero:
            String(localized: "backdrop.shader.aero.attribution", defaultValue: "Live · bubbles drift aside from the pointer", bundle: .localizedModule)
        case .sakura:
            String(localized: "backdrop.shader.sakura.attribution", defaultValue: "Live · the pointer parts the petals", bundle: .localizedModule)
        case .sumi:
            String(localized: "backdrop.shader.sumi.attribution", defaultValue: "Live · click to drop ink", bundle: .localizedModule)
        case .koi:
            String(localized: "backdrop.shader.koi.attribution", defaultValue: "Live · the koi swim clear of the pointer", bundle: .localizedModule)
        case .snowfall:
            String(localized: "backdrop.shader.snowfall.attribution", defaultValue: "Live · the pointer sends a gust through the snow", bundle: .localizedModule)
        case .lanterns:
            String(localized: "backdrop.shader.lanterns.attribution", defaultValue: "Live · lanterns near the pointer glow", bundle: .localizedModule)
        case .rain:
            String(localized: "backdrop.shader.rain.attribution", defaultValue: "Live · rain trickles down the glass", bundle: .localizedModule)
        case .matrix:
            String(localized: "backdrop.shader.matrix.attribution", defaultValue: "Live · blocks of dots light up around the pointer", bundle: .localizedModule)
        }
    }

    /// The picker group every shader is listed under.
    public static let collection = "shaders"

    /// The picker group's title.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.shader", defaultValue: "Living wallpapers", bundle: .localizedModule)
    }

    /// The fragment function drawing this shader in ``BackdropShaderSource``.
    var fragmentName: String { "wp_" + rawValue }

    /// Where the shader's clock starts, in seconds: a still at 0 would show the noise before it
    /// has flowed, so every poster and first frame starts a little way in.
    var startTime: Float {
        switch self {
        case .currents: 42
        case .ripples: 17
        case .aurora: 63
        case .field: 9
        case .aero: 63
        case .sakura: 31
        case .sumi: 24
        case .koi: 12
        case .snowfall: 40
        case .lanterns: 55
        case .rain: 20
        case .matrix: 21
        }
    }

    /// The still of this shader for light or `dark`, rendered on first decode
    /// (``BackdropShaderRenderer/preparePoster(at:)``). Its name carries
    /// ``BackdropShaderSource/version``, so a changed shader never shows an old still.
    public func posterURL(dark: Bool) -> URL {
        Self.posterFolder.appendingPathComponent("\(rawValue)-\(dark ? "dark" : "light")-v\(BackdropShaderSource.version).png")
    }

    /// The folder the posters are rendered into.
    static let posterFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-next", isDirectory: true)
            .appendingPathComponent("backdrop-shaders", isDirectory: true)
    }()

    /// The shader and appearance a poster file is the still of; nil for any other file.
    static func poster(at url: URL) -> (shader: BackdropShader, dark: Bool)? {
        guard url.deletingLastPathComponent().standardizedFileURL.path == posterFolder.standardizedFileURL.path else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 3, let shader = BackdropShader(rawValue: String(parts[0])) else { return nil }
        return (shader, parts[1] == "dark")
    }
}
