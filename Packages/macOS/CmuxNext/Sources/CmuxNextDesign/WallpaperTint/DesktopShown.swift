public import CmuxNextDesignTokens
public import Foundation

/// What one screen's desktop shows, resolved to a file the window can draw or play: the picture
/// (a rotation's current file, a description's still, the fill color when there is none), the
/// aerial movie of a moving desktop, or a dynamic picture's frame for the time of day; with how
/// macOS places it (``BackdropArtFit``) and the fill color around it.
///
/// A window showing the Desktop Wallpaper (``BackdropSelection/desktop``) draws ``selection(dark:)``,
/// an ordinary picture, movie or moment choice, so the image cache, the video path and the
/// appearance handling work for it as for any other background.
public nonisolated struct DesktopShown: Hashable, Sendable {
    /// The file shown: a picture that decodes, or a movie.
    public let path: String
    /// A dynamic picture's frame for now; nil when the appearance picks it (or it is a still).
    public let frame: Int?
    /// How macOS places it.
    public let fit: BackdropArtFit
    /// The sRGB fill color around a fitted or centered picture, 0...1.
    public let fill: [Double]
    /// When ``frame`` next changes (the time of day moved on); not part of equality.
    public let nextChange: Date?

    public init(path: String, frame: Int? = nil, fit: BackdropArtFit = .fill, fill: [Double] = [0, 0, 0], nextChange: Date? = nil) {
        self.path = path
        self.frame = frame
        self.fit = fit
        self.fill = fill
        self.nextChange = nextChange
    }

    /// Whether it is a movie (an aerial desktop).
    public var isVideo: Bool { AppleWallpapers.isVideo(path) }

    /// The background a window draws for it in light or `dark`.
    public func selection(dark: Bool) -> BackdropSelection {
        if let frame { return .moment(path: path, frame: frame, dark: dark) }
        return .system(path: path)
    }

    /// What `picture` shows at `date`: the aerial the store's `choice` names when it is downloaded,
    /// else the picture resolved to a file and, for a dynamic one, the frame of the time.
    /// Reads files (the store's cache keeps their metadata), so call it off the main thread.
    /// - Parameters:
    ///   - picture: What macOS reports for the screen.
    ///   - dark: Whether the app is in the dark appearance.
    ///   - choice: The store's desktop choice for the screen; nil when unknown.
    ///   - date: Now.
    ///   - cache: Where the dynamic metadata and aerial lookups are kept.
    /// - Returns: Nil only when no file can be drawn at all.
    static func resolve(_ picture: DesktopPicture, dark: Bool, choice: DesktopStoreChoice?, at date: Date,
                        cache: DesktopStoreCache) -> DesktopShown? {
        let fill = [picture.fill.red, picture.fill.green, picture.fill.blue]
        if let choice, choice.isAerial, let movie = cache.aerial(choice.aerialIDs) {
            return DesktopShown(path: movie, fit: picture.fit, fill: fill)
        }
        guard let url = picture.resolvedURL(dark: dark) else { return nil }
        let frames = cache.frames(of: url), motion = choice?.motion
        // The frame holds until its next change: a re-read before then reuses it, not the search.
        let moment = cache.moment(of: url.path, motion: motion, at: date) {
            let timeZone = TimeZone.current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return DesktopStoreChoice.frame(of: frames, motion: motion, at: date, location: BackdropLocation.of(timeZone), calendar: calendar)
        }
        return DesktopShown(path: url.path, frame: moment.index, fit: picture.fit, fill: fill, nextChange: moment.next)
    }

    public static func == (lhs: DesktopShown, rhs: DesktopShown) -> Bool {
        lhs.path == rhs.path && lhs.frame == rhs.frame && lhs.fit == rhs.fit && lhs.fill == rhs.fill
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(frame)
        hasher.combine(fit)
        hasher.combine(fill)
    }
}
