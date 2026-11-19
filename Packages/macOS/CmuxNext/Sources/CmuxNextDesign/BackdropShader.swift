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
    /// Soft color fields that lean toward the pointer: the calmest of them.
    case mesh
    /// Topographic contour lines; the pointer raises a hill.
    case contours
    /// Lava-lamp blobs that merge and split; the pointer is one more blob.
    case lava
    /// Underwater light on sand; the pointer gathers it like a lens.
    case caustics
    /// Drifting Voronoi cells; the pointer pulls the nearest one.
    case cells
    /// Two ring patterns beating into moiré fringes; one follows the pointer.
    case moire
    /// Interlocking arc tiles that turn over near the pointer.
    case truchet
    /// A printer's dot screen whose dots swell near the pointer.
    case halftone

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
        case .currents: String(localized: "backdrop.shader.currents", defaultValue: "Currents", bundle: .module)
        case .ripples: String(localized: "backdrop.shader.ripples", defaultValue: "Ripples", bundle: .module)
        case .aurora: String(localized: "backdrop.shader.aurora", defaultValue: "Aurora", bundle: .module)
        case .field: String(localized: "backdrop.shader.field", defaultValue: "Dot Field", bundle: .module)
        case .mesh: String(localized: "backdrop.shader.mesh", defaultValue: "Mesh", bundle: .module)
        case .contours: String(localized: "backdrop.shader.contours", defaultValue: "Contours", bundle: .module)
        case .lava: String(localized: "backdrop.shader.lava", defaultValue: "Lava", bundle: .module)
        case .caustics: String(localized: "backdrop.shader.caustics", defaultValue: "Caustics", bundle: .module)
        case .cells: String(localized: "backdrop.shader.cells", defaultValue: "Cells", bundle: .module)
        case .moire: String(localized: "backdrop.shader.moire", defaultValue: "Moiré", bundle: .module)
        case .truchet: String(localized: "backdrop.shader.truchet", defaultValue: "Truchet", bundle: .module)
        case .halftone: String(localized: "backdrop.shader.halftone", defaultValue: "Halftone", bundle: .module)
        }
    }

    /// The line under the title: what the pointer does to it.
    public var attribution: String {
        switch self {
        case .currents:
            String(localized: "backdrop.shader.currents.attribution", defaultValue: "Live · the pointer stirs the ink", bundle: .module)
        case .ripples:
            String(localized: "backdrop.shader.ripples.attribution", defaultValue: "Live · click to drop a ripple", bundle: .module)
        case .aurora:
            String(localized: "backdrop.shader.aurora.attribution", defaultValue: "Live · the light leans toward the pointer", bundle: .module)
        case .field:
            String(localized: "backdrop.shader.field.attribution", defaultValue: "Live · the pointer pushes the dots aside", bundle: .module)
        case .mesh:
            String(localized: "backdrop.shader.mesh.attribution", defaultValue: "Live · the colors lean toward the pointer", bundle: .module)
        case .contours:
            String(localized: "backdrop.shader.contours.attribution", defaultValue: "Live · the pointer raises a hill", bundle: .module)
        case .lava:
            String(localized: "backdrop.shader.lava.attribution", defaultValue: "Live · the pointer is one more blob", bundle: .module)
        case .caustics:
            String(localized: "backdrop.shader.caustics.attribution", defaultValue: "Live · the pointer gathers the light", bundle: .module)
        case .cells:
            String(localized: "backdrop.shader.cells.attribution", defaultValue: "Live · the pointer pulls the nearest cell", bundle: .module)
        case .moire:
            String(localized: "backdrop.shader.moire.attribution", defaultValue: "Live · one pattern follows the pointer", bundle: .module)
        case .truchet:
            String(localized: "backdrop.shader.truchet.attribution", defaultValue: "Live · tiles turn over near the pointer", bundle: .module)
        case .halftone:
            String(localized: "backdrop.shader.halftone.attribution", defaultValue: "Live · the dots swell near the pointer", bundle: .module)
        }
    }

    /// The picker group every shader is listed under.
    public static let collection = "shaders"

    /// The picker group's title.
    public static var collectionTitle: String {
        String(localized: "backdrop.collection.shader", defaultValue: "Living wallpapers", bundle: .module)
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
        case .mesh: 31
        case .contours: 55
        case .lava: 74
        case .caustics: 12
        case .cells: 26
        case .moire: 38
        case .truchet: 47
        case .halftone: 21
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
