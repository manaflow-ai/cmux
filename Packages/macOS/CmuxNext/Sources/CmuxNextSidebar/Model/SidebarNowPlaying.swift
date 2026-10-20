public import Foundation

/// The sidebar's Now Playing card (cx-ouoxo, a preview feature): what a
/// Now Playing source plays, its artwork, and which controls it takes. The
/// App fills it from its source (the playing browser tab first) with the
/// labels localized; the card sends `SidebarIntent.nowPlaying` back.
public nonisolated struct SidebarNowPlaying: Hashable, Sendable {
    public var title: String
    public var artist: String
    /// The artwork's image data (PNG, small), nil without artwork.
    public var artwork: Data?
    public var isPlaying: Bool
    /// The playback position at `positionDate`, in seconds; nil when the
    /// source does not report one (a live stream, an old page).
    public var position: TimeInterval?
    /// The length in seconds; nil when unknown or endless.
    public var duration: TimeInterval?
    /// How fast the position moves while playing (1 is normal speed).
    public var rate: Double
    /// When `position` was read; the card moves on from it while playing.
    public var positionDate: Date
    public var canPrevious: Bool
    public var canNext: Bool
    public var labels: Labels
    /// The app that plays, for the New Tab player's Open in; nil for cmux's own player and tabs.
    public var app: App?

    /// Another app that plays (Spotify, Music): its bundle identifier and its name as Finder shows it.
    public struct App: Hashable, Sendable {
        public var bundleIdentifier: String
        public var name: String

        public init(bundleIdentifier: String, name: String) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
        }
    }

    /// The controls' titles and VoiceOver labels.
    public struct Labels: Hashable, Sendable {
        public var play: String
        public var pause: String
        public var previous: String
        public var next: String

        public init(play: String, pause: String, previous: String, next: String) {
            self.play = play
            self.pause = pause
            self.previous = previous
            self.next = next
        }
    }

    public init(title: String, artist: String = "", artwork: Data? = nil, isPlaying: Bool, position: TimeInterval? = nil,
                duration: TimeInterval? = nil, rate: Double = 1, positionDate: Date = Date(), canPrevious: Bool = false,
                canNext: Bool = false, labels: Labels, app: App? = nil) {
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.rate = rate
        self.positionDate = positionDate
        self.canPrevious = canPrevious
        self.canNext = canNext
        self.labels = labels
        self.app = app
    }

    /// Seeking needs a position inside a known length.
    public var canSeek: Bool { position != nil && (duration ?? 0) > 0 }

    /// The position at `date`: it moves on while playing, kept inside the length.
    public func position(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        let moved = isPlaying ? position + max(0, date.timeIntervalSince(positionDate)) * rate : position
        return min(max(0, moved), duration ?? .infinity)
    }
}

/// What the Now Playing card asks its source to do.
public nonisolated enum SidebarNowPlayingCommand: Hashable, Sendable {
    case playPause
    case previous
    case next
    /// Moves to this many seconds in.
    case seek(TimeInterval)
}
