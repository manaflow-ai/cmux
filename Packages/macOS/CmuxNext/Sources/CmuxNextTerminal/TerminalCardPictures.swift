public import CoreGraphics

/// Keeps each terminal's picture past this run as it leaves the screen, so a hover card (a tab's, the sidebar
/// workspace card's split miniature) shows it after a relaunch too, before the terminal is shown again (#56159).
///
/// The user, 2026-11-25: "the terminal and chat previews dont seem to show up". Every picture of a terminal lived in
/// memory (its surface's frame, the picture taken as it paused, an evicted one's), and the frames saved at quit are
/// only the terminals on screen then (`TerminalLaunchFrames`). After a relaunch a terminal in any other workspace has
/// no surface until it is shown, so its card had nothing to draw; browser tabs kept theirs on disk and showed.
///
/// A leave renders one picture (at most ``side`` px) off the main thread, at most once a ``freshness`` per terminal
/// (switching back and forth costs one encode and write per that, not one per switch); `save` keeps it (the app's disk
/// store, which drops a closed tab's). A render still running when its tab closes (``forget(_:)``) is dropped, so a
/// closed tab's picture is never written after it went.
@MainActor
public final class TerminalCardPictures {
    /// A kept picture's longest side, in pixels: a hover card's thumbnail at most.
    public static let side: CGFloat = 640

    /// Keeps `image` as tab `key`'s picture.
    public typealias Save = @MainActor (_ key: String, _ image: CGImage) -> Void

    private let save: Save
    /// A terminal pictured this recently is not pictured again as it leaves the screen.
    public static let freshness: Duration = .seconds(30)
    /// When each tab's last picture was kept.
    private var times: [String: ContinuousClock.Instant] = [:]
    /// Each tab's render in flight, by its token: ``forget(_:)`` drops it, and its picture with it.
    private var inFlight: [String: UInt64] = [:]
    private var nextToken: UInt64 = 0
    private let now: () -> ContinuousClock.Instant

    public init(now: @escaping () -> ContinuousClock.Instant = { .now }, save: @escaping Save) { (self.now, self.save) = (now, save) }

    /// Tab `key`'s terminal `session` is leaving the screen (its surface still holds its last frame): its picture is
    /// rendered and kept, unless it is unchanged since the last one.
    public func willLeaveScreen(_ key: String, session: TerminalSession) {
        guard inFlight[key] == nil, times[key].map({ now() - $0 >= Self.freshness }) ?? true else { return }
        nextToken &+= 1
        let token = nextToken
        inFlight[key] = token
        Task { [weak self] in  // task-owner: one bounded off-main render per leave, at most one a `freshness` per terminal
            let image = await session.shownFrameInBackground(maxPixelSize: Self.side)
            guard let self, inFlight[key] == token else { return }  // closed meanwhile: its picture goes with it
            inFlight[key] = nil
            guard let image else { return }
            times[key] = now()
            save(key, image)
        }
    }

    /// Tab `key` closed: a render in flight for it is dropped.
    public func forget(_ key: String) { (times[key], inFlight[key]) = (nil, nil) }
}
