public import Foundation

/// The user's window background image choice: one image painted behind the
/// titlebar, sidebar and every terminal pane of a cmux window.
///
/// The image is drawn over an opaque fill of the terminal background color, at
/// ``opacity``. A low opacity keeps terminal text readable because most of each
/// pixel is still the theme's background color.
///
/// The value is persisted in `UserDefaults` under the keys below. The settings
/// catalog and the window chrome both read those keys, so they live here, in
/// the package both depend on.
///
/// ```swift
/// let settings = WindowBackgroundImageSettings(
///     path: "~/Pictures/wallpaper.jpg",
///     opacity: 0.25,
///     fit: .cover
/// )
/// let url = settings.resolvedFileURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
/// ```
public struct WindowBackgroundImageSettings: Equatable, Sendable {
    /// `UserDefaults` key for ``path``.
    public static let pathDefaultsKey = "windowBackgroundImagePath"

    /// `UserDefaults` key for ``opacity``.
    public static let opacityDefaultsKey = "windowBackgroundImageOpacity"

    /// `UserDefaults` key for ``fit``.
    public static let fitDefaultsKey = "windowBackgroundImageFit"

    /// Default ``opacity``. Low enough that text over a busy photo stays
    /// readable on both light and dark themes.
    public static let defaultOpacity = 0.25

    /// Default ``fit``: fill the window without distorting the image.
    public static let defaultFit = WindowBackgroundImageFit.cover

    /// No background image. This is the default, so the window looks exactly
    /// as it does without the feature.
    public static let none = WindowBackgroundImageSettings(path: "")

    /// The image path as the user wrote it: absolute, or starting with `~/`.
    /// Empty means no image.
    public let path: String

    /// How visible the image is over the terminal background color, clamped
    /// to `0...1`.
    public let opacity: Double

    /// How the image is scaled to the window.
    public let fit: WindowBackgroundImageFit

    /// Creates background image settings.
    ///
    /// - Parameters:
    ///   - path: The image path as written by the user. Surrounding whitespace
    ///     is ignored.
    ///   - opacity: Image visibility. Values outside `0...1` are clamped, and a
    ///     non-finite value falls back to ``defaultOpacity``.
    ///   - fit: How the image is scaled to the window.
    public init(
        path: String,
        opacity: Double = WindowBackgroundImageSettings.defaultOpacity,
        fit: WindowBackgroundImageFit = WindowBackgroundImageSettings.defaultFit
    ) {
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : Self.defaultOpacity
        self.fit = fit
    }

    /// Whether the user picked an image. The file may still be missing or
    /// unreadable; the window then shows only the terminal background color.
    public var isEnabled: Bool {
        !path.isEmpty
    }

    /// The image file URL, or `nil` when no image is set or the path is
    /// relative. A leading `~` expands to `homeDirectory`.
    ///
    /// Relative paths are rejected because cmux has no stable working directory
    /// to resolve them against.
    ///
    /// - Parameter homeDirectory: The directory `~` expands to.
    /// - Returns: The file URL to load, or `nil`.
    public func resolvedFileURL(homeDirectory: URL) -> URL? {
        if path == "~" {
            return nil
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: false)
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    /// Reads the settings from `UserDefaults`, using the defaults above for
    /// missing or malformed values.
    ///
    /// - Parameter defaults: The store to read.
    /// - Returns: The persisted settings, or ``none`` when no path is stored.
    public static func load(from defaults: UserDefaults) -> Self {
        let fit = defaults.string(forKey: fitDefaultsKey)
            .flatMap(WindowBackgroundImageFit.init(rawValue:)) ?? defaultFit
        return Self(
            path: defaults.string(forKey: pathDefaultsKey) ?? "",
            opacity: (defaults.object(forKey: opacityDefaultsKey) as? NSNumber)?.doubleValue ?? defaultOpacity,
            fit: fit
        )
    }
}
