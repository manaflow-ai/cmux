public import CoreGraphics
import CmuxNextWakeups

/// Live pictures of tabs for the hover cards that show them (the sidebar card's split miniature, a tab's card).
///
/// A card watches each tab it pictures (``watch(_:maxPixelSize:onPicture:)``) and stops when it hides; a tab nobody
/// watches costs nothing: no observer, no timer, no capture. A watched tab is pictured again only after its content
/// changed (its ``Source/observe`` says so: a terminal's new frame, a chat's push, a page's load), at once after a
/// quiet spell and then at most once a ``Source/gap``, one capture at a time (`PanePictureSchedule`, the Rust rules of
/// `cmux-pane-pictures`). The last picture of the last few tabs watched stays, with the content revision it shows, so
/// a card opened again draws it at once and pictures the tab again only when it moved on.
///
/// Leo, 2026-11-24: "our hover preview should be able to do it. at very low cost, at very low resource usage, cached,
/// and rapidly able to reflect changes."
@MainActor
public final class PanePictureWatch {
    /// What one capture of a tab gave.
    public enum Capture {
        /// A new picture of the tab as it shows now.
        case picture(CGImage)
        /// The tab cannot be pictured now (a hidden Chromium page, a shell showing only its prompt): its last picture,
        /// if any. Not tried again until the tab changes or a card watches it again.
        case kept(CGImage?)
        /// The engine gave nothing; tried again after a backoff.
        case failed
    }

    /// How one tab is pictured.
    public struct Source {
        /// The least time between two captures, in ms (``terminalGap``, ``pageGap``).
        public var gap: UInt64
        /// The tab's content revision now (a terminal's frame count, a chat's pushes); nil when it has none, so each
        /// new watch pictures it again.
        public var revision: @MainActor () -> UInt64?
        /// Starts telling `changed` each time the content changes; returns the stop. Runs while a card watches.
        public var observe: @MainActor (_ changed: @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)
        /// One picture of the tab, at most the given pixel size.
        public var capture: @MainActor (CGSize) async -> Capture

        public init(gap: UInt64, revision: @escaping @MainActor () -> UInt64?,
                    observe: @escaping @MainActor (_ changed: @escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void),
                    capture: @escaping @MainActor (CGSize) async -> Capture) {
            (self.gap, self.revision, self.observe, self.capture) = (gap, revision, observe, capture)
        }
    }

    /// A terminal's gap: its frame is one GPU blit off the main thread.
    public static let terminalGap = PanePictureSchedule.terminalGap
    /// A page's gap (a browser tab, a chat, a Markdown page): its capture costs the main thread a Chromium encode.
    public static let pageGap = PanePictureSchedule.pageGap
    /// How many unwatched tabs keep their last picture: a few cards' worth, about 2.5 MB of 640 px pictures.
    static let capacity = 16

    /// How tab `key` is pictured; nil (or a nil source) pictures nothing.
    public var source: (@MainActor (String) -> Source?)?

    private struct Viewer {
        let size: CGSize
        let onPicture: @MainActor (CGImage) -> Void
    }

    private final class Entry {
        var source: Source
        var schedule: PanePictureSchedule
        let timer = DemandTimer(owner: "hover-card.pane-pictures")
        var viewers: [Int: Viewer] = [:]
        var stopObserving: (@MainActor () -> Void)?
        var picture: CGImage?
        /// The revision ``picture`` shows; nil when unknown.
        var pictured: UInt64?
        /// The size ``picture`` was asked at: a larger viewer pictures the tab again.
        var pictureSize = CGSize.zero

        init(_ source: Source) { (self.source, schedule) = (source, PanePictureSchedule(gap: source.gap)) }

        nonisolated deinit { timer.cancel() }
    }

    private var entries: [String: Entry] = [:]
    /// Least recently watched first.
    private var order: [String] = []
    private var nextViewer = 0
    private static let origin = ContinuousClock.now

    public init(source: (@MainActor (String) -> Source?)? = nil) { self.source = source }

    /// Shows tab `key` to `onPicture`: its last picture now, when there is one, then each new one while the watch
    /// lasts. Returns the stop (idempotent); a card calls it when it hides.
    public func watch(_ key: String, maxPixelSize: CGSize, onPicture: @escaping @MainActor (CGImage) -> Void) -> @MainActor () -> Void {
        guard let entry = entry(for: key) else { return {} }
        let id = nextViewer
        nextViewer += 1
        entry.viewers[id] = Viewer(size: maxPixelSize, onPicture: onPicture)
        if let picture = entry.picture { onPicture(picture) }
        if entry.viewers.count == 1 {
            start(entry, key)
        } else if !Self.fits(maxPixelSize, in: entry.pictureSize) {
            arm(entry, key, entry.schedule.note(.damaged, now: Self.now()))
        }
        return { [weak self] in self?.unwatch(key, id) }
    }

    /// The last picture of `key`, if any (tests, a drag ghost).
    public func picture(of key: String) -> CGImage? { entries[key]?.picture }

    /// Every kept picture is out of date (the theme changed): each tab is pictured again, now when watched, else at
    /// its next watch.
    public func invalidateAll() {
        let now = Self.now()
        for (key, entry) in entries {
            entry.pictured = nil
            if !entry.viewers.isEmpty { arm(entry, key, entry.schedule.note(.damaged, now: now)) }
        }
    }

    private func entry(for key: String) -> Entry? {
        if let entry = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            // Unwatched, its tab may have changed kind (a chat made, a terminal attached): how it is pictured is asked again.
            if entry.viewers.isEmpty, let source = source?(key) { (entry.source, entry.schedule) = (source, PanePictureSchedule(gap: source.gap)) }
            return entry
        }
        guard let source = source?(key) else { return nil }
        let entry = Entry(source)
        entries[key] = entry
        order.append(key)
        return entry
    }

    private func start(_ entry: Entry, _ key: String) {
        let now = Self.now()
        var due = entry.schedule.note(.watched, now: now)
        let revision = entry.source.revision()
        let size = entry.viewers.values.first?.size ?? .zero
        if entry.picture == nil || revision == nil || revision != entry.pictured || !Self.fits(size, in: entry.pictureSize) {
            due = entry.schedule.note(.damaged, now: now)
        }
        entry.stopObserving = entry.source.observe { [weak self, weak entry] in
            guard let self, let entry, !entry.viewers.isEmpty else { return }
            self.arm(entry, key, entry.schedule.note(.damaged, now: Self.now()))
        }
        arm(entry, key, due)
    }

    private func unwatch(_ key: String, _ id: Int) {
        guard let entry = entries[key], entry.viewers.removeValue(forKey: id) != nil, entry.viewers.isEmpty else { return }
        entry.stopObserving?()
        entry.stopObserving = nil
        entry.schedule.note(.unwatched, now: Self.now())
        entry.timer.cancel()
        trim()
    }

    /// Drops the least recently watched unwatched tabs past ``capacity``.
    private func trim() {
        var unwatched = order.filter { entries[$0]?.viewers.isEmpty == true }
        while unwatched.count > Self.capacity {
            let key = unwatched.removeFirst()
            entries[key] = nil
            order.removeAll { $0 == key }
        }
    }

    /// One timer per watched tab, at its next due time; none when nothing is due.
    private func arm(_ entry: Entry, _ key: String, _ due: UInt64?) {
        guard let due, !entry.viewers.isEmpty else { return }
        let now = Self.now()
        let delay = Duration.milliseconds(Int64(due > now ? due - now : 0))
        // hover-timing: a watched tab's next picture, due after its content changed; never armed with no card open
        entry.timer.schedule(after: delay) { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            self.capture(entry, key)
        }
    }

    private func capture(_ entry: Entry, _ key: String) {
        guard !entry.viewers.isEmpty, let generation = entry.schedule.takeDue(now: Self.now()) else { return }
        let size = entry.viewers.values.reduce(CGSize.zero) { CGSize(width: max($0.width, $1.size.width), height: max($0.height, $1.size.height)) }
        let revision = entry.source.revision()
        let schedule = entry.schedule  // a tab watched again later gets a new one: this capture reports to its own
        Task { [weak self, entry] in  // task-owner: one capture of a watched tab; its schedule allows one at a time
            let result = await entry.source.capture(size)
            guard entry.schedule === schedule else { return }  // started for an earlier watch: a newer capture owns it
            let outcome: PanePictureSchedule.Outcome
            switch result {
            case .picture(let image):
                (entry.picture, entry.pictured, entry.pictureSize) = (image, revision, size)
                outcome = .done
            case .kept(let image):
                // A last picture (a hidden page's leave picture) only fills a tab with none: it may be older than ours.
                if let image, entry.picture == nil { (entry.picture, entry.pictured, entry.pictureSize) = (image, nil, size) }
                outcome = .unavailable
            case .failed:
                outcome = .failed
            }
            let due = schedule.finish(generation, outcome, now: Self.now())
            if let picture = entry.picture, outcome != .failed { entry.viewers.values.forEach { $0.onPicture(picture) } }
            self?.arm(entry, key, due)
        }
    }

    /// Whether a picture asked at `taken` serves a viewer asking `size`.
    private static func fits(_ size: CGSize, in taken: CGSize) -> Bool { size.width <= taken.width && size.height <= taken.height }

    /// Milliseconds since this process first asked.
    private static func now() -> UInt64 {
        let elapsed = ContinuousClock.now - origin
        return UInt64(max(0, elapsed.components.seconds)) * 1000 + UInt64(max(0, elapsed.components.attoseconds) / 1_000_000_000_000_000)
    }
}
