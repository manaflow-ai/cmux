public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
import ImageIO
import UniformTypeIdentifiers

/// The browser pages' last pictures, saved at quit and drawn over each pane at launch until its page shows its
/// first content, so a relaunch shows the page the pane showed, not the theme color, while
/// Chromium starts. Chrome does this on Android (`StartupPaintPreview`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java): the restored tab shows its saved capture
/// until the live page's first meaningful paint, and drops it on any mismatch.
///
/// One JPEG per page that was on screen, in a folder per browser profile (`<profile UUID>/<tab key>.jpg`) with an
/// index of each picture's pane size and page frame, mode 0600 in folders of mode 0700. A save replaces the
/// whole set. An off-the-record page (incognito), a page holding Secure Input, a page with protected media and
/// a window hidden from screen capture are never captured, so never written: their panes show the theme
/// background, which is what the fill of a whole-window picture shows.
///
/// The launch reads and decodes every picture off the main thread from its start (``prefetch(mark:)``, in
/// the app's `main` before `NSApplication.run`). A pane asks with ``take(_:profile:)`` at its first frame and
/// never waits: it gets its picture when the read has ended (``LaunchRead``), else nothing. Each picture is
/// handed out once; the ones no pane asked for are dropped 30 s on (``dropUnasked(after:on:)``; decoded pictures
/// are large).
///
/// ```swift
/// let pictures = BrowserLaunchPictures(state: stateDirectory, work: work)
/// pictures.prefetch { DebugTimings.markLaunch($0) }
/// pictures.dropUnasked(after: .seconds(30), on: MainDeadline(owner: "browser.launch-pictures.keep",
///                                                            workClass: .background, scheduler: deadlines))
/// let picture = pictures.take(tabKey, profile: profileID)   // at the pane's first frame
/// ```
@MainActor
public final class BrowserLaunchPictures {
    /// The folder of the saved pictures in the tag's state directory.
    public static let directoryName = "browser-launch-pictures"
    /// A larger picture file is not read.
    nonisolated static let maximumBytes = 16 << 20
    /// A larger index file is not read.
    nonisolated static let maximumIndexBytes = 256 << 10
    /// The most pictures one save writes and one launch reads (one per pane on screen at the last quit).
    nonisolated static let maximumPictures = 64
    nonisolated static let indexName = "pictures.json"

    /// A page's picture from the last quit, decoded.
    public nonisolated struct Picture: Sendable {
        /// The page's pixels.
        public let image: CGImage
        /// The size of the pane's content area (toolbar and page) at the quit: a pane of another size shows nothing.
        public let paneSize: CGSize
        /// Where the page sat in that area, from its top-left corner, in points.
        public let pageFrame: CGRect

        public init(image: CGImage, paneSize: CGSize, pageFrame: CGRect) {
            (self.image, self.paneSize, self.pageFrame) = (image, paneSize, pageFrame)
        }
    }

    /// A page on screen at the quit, as the quit saves it. The quit makes none of a page whose picture must never
    /// reach the disk (the app's `TabContentCache.launchPictureShots`), so every shot is written.
    public nonisolated struct Shot: Sendable {
        public let key: String
        public let profile: UUID
        public let picture: Picture

        public init(key: String, profile: UUID, picture: Picture) {
            (self.key, self.profile, self.picture) = (key, profile, picture)
        }
    }

    /// A picture's place: its profile and tab.
    nonisolated struct Slot: Hashable, Sendable {
        let profile: UUID
        let key: String
    }

    /// One picture of a profile folder's index.
    nonisolated struct IndexEntry: Codable, Sendable {
        let key: String
        let pane: CGSize
        let page: CGRect
    }

    let directory: URL?
    private let work: BackgroundWork
    private let reader: LaunchFileReader
    /// Drops the read's pictures no pane took (``dropUnasked(after:on:)``); nil until the app arms it.
    private var discard: MainDeadline?
    /// The launch read of the saved pictures, decoded; nil before it starts and once its pictures are dropped.
    private var read: LaunchRead<[Slot: Picture]>?
    /// The pictures handed out (each once per launch).
    private var taken: Set<Slot> = []
    private var mark: @Sendable (String) -> Void = { _ in }
    /// The read's results were dropped: ``prefetch(mark:)`` starts no new read.
    private var readDropped = false

    /// - Parameters:
    ///   - directory: The saved pictures' folder; nil keeps none.
    ///   - work: The app's blocking-work lanes: the read, the encode and the writes run on its files lane.
    ///   - reader: Reads the files; default from disk (tests record where it runs, or hold it).
    public init(directory: URL?, work: BackgroundWork, reader: LaunchFileReader = LaunchFileReader()) {
        self.directory = directory
        self.work = work
        self.reader = reader
    }

    /// The pictures in `state`, the tag's state directory (beside its launch snapshot).
    /// `reader` reads the saved pictures; the app's skips every one in a crash streak's safe launch (`LaunchSafeMode`).
    public convenience init(state: URL?, work: BackgroundWork, reader: LaunchFileReader = LaunchFileReader()) {
        self.init(directory: state?.appending(path: Self.directoryName, directoryHint: .isDirectory), work: work, reader: reader)
    }

    /// Starts reading and decoding every saved picture on the files lane at once; a later call does nothing.
    ///
    /// It runs before the app's main-thread scheduler exists; the app arms the drop of the untaken pictures with
    /// ``dropUnasked(after:on:)`` once it does.
    ///
    /// - Parameter mark: Records the launch marks `browser.launch_pictures_read` (on the lane, when the pictures
    ///   are decoded), `browser.launch_picture_missed` (a pane asked before that and showed none) and
    ///   `browser.launch_pictures_dropped` (the untaken pictures went).
    public func prefetch(mark: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let directory, read == nil, !readDropped else { return }
        self.mark = mark
        let reader = reader
        read = LaunchRead(on: work, dropped: [:]) {
            let pictures = Self.readAll(in: directory, reader)
            mark("browser.launch_pictures_read")
            return pictures
        }
    }

    /// Drops the pictures no pane took `keep` from now (decoded pictures are large), on `deadline`, which this keeps.
    public func dropUnasked(after keep: Duration, on deadline: MainDeadline) {
        guard !readDropped else { return }
        discard?.cancel()
        discard = deadline
        deadline.schedule(after: keep) { [weak self] in self?.dropUnasked() }
    }

    /// Returns once the launch read has ended (at once when none runs).
    public func readFinished() async {
        _ = await read?.finished()
    }

    /// Drops the read's pictures that no pane took; later asks get none.
    public func dropUnasked() {
        guard !readDropped else { return }
        if read != nil { mark("browser.launch_pictures_dropped") }
        read = nil
        readDropped = true
        discard?.cancel()
        discard = nil
    }

    /// Tab `key`'s picture from the last quit, saved under browser profile `profile`, at once and never waiting:
    /// nil while the read runs (the pane shows what it shows with no picture), for a tab the last quit saved
    /// none of, or one already handed out.
    public func take(_ key: String, profile: UUID) -> Picture? {
        guard let read else { return nil }
        guard let pictures = read.value else {
            mark("browser.launch_picture_missed")
            return nil
        }
        let slot = Slot(profile: profile, key: key)
        guard let picture = pictures[slot], taken.insert(slot).inserted else { return nil }
        return picture
    }

    /// Replaces the saved pictures with `shots`; with none, the folder goes.
    public func save(_ shots: [Shot]) async {
        guard let directory else { return }
        _ = try? await work.run(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { Self.write(shots, to: directory) }
    }

    /// Every saved picture under `directory`, decoded, by profile and tab: at most ``maximumPictures``, each of
    /// a profile folder's index whose file reads and decodes.
    nonisolated static func readAll(in directory: URL, _ reader: LaunchFileReader) -> [Slot: Picture] {
        let profiles = ((try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []).sorted().compactMap(UUID.init(uuidString:))
        var pictures: [Slot: Picture] = [:]
        for profile in profiles {
            let folder = directory.appending(path: profile.uuidString, directoryHint: .isDirectory)
            guard let index = reader.data(at: folder.appending(path: indexName), maximumBytes: maximumIndexBytes),
                  let entries = try? JSONDecoder().blockingDecode([IndexEntry].self, from: index) else { continue }
            for entry in entries where isFileSafe(entry.key) && entry.pane.width > 0 && entry.pane.height > 0 {
                guard pictures.count < maximumPictures else { return pictures }
                guard let image = reader.image(at: folder.appending(path: fileName(entry.key)), maximumBytes: maximumBytes) else { continue }
                pictures[Slot(profile: profile, key: entry.key)] = Picture(image: image, paneSize: entry.pane, pageFrame: entry.page)
            }
        }
        return pictures
    }

    /// Writes the shots by profile, replacing whatever the folder held.
    nonisolated static func write(_ shots: [Shot], to directory: URL) {
        var byProfile: [UUID: [(entry: IndexEntry, data: Data)]] = [:]
        for shot in shots.prefix(maximumPictures) where isFileSafe(shot.key) {
            let picture = shot.picture
            guard picture.paneSize.width > 0, picture.paneSize.height > 0, picture.pageFrame.width > 0,
                  let data = jpeg(picture.image) else { continue }
            byProfile[shot.profile, default: []].append((IndexEntry(key: shot.key, pane: picture.paneSize, page: picture.pageFrame), data))
        }
        let manager = FileManager.checked
        try? manager.removeItem(at: directory)
        guard !byProfile.isEmpty else { return }
        for (profile, files) in byProfile {
            let folder = directory.appending(path: profile.uuidString, directoryHint: .isDirectory)
            guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            for file in files { writePrivate(file.data, to: folder.appending(path: fileName(file.entry.key))) }
            // The index last: a quit that ends before it leaves a folder the next launch does not read.
            if let index = try? JSONEncoder().encode(files.map(\.entry)) { writePrivate(index, to: folder.appending(path: indexName)) }
        }
    }

    /// `image` as a JPEG over white (JPEG keeps no alpha: a transparent pixel would turn black; white is the web's
    /// default page background), in its own RGB color space.
    nonisolated static func jpeg(_ image: CGImage, quality: Double = 0.8) -> Data? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        let data = NSMutableData()
        guard let opaque = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard blockingImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private nonisolated static func writePrivate(_ data: Data, to url: URL) {
        guard (try? data.blockingWrite(to: url, options: [.atomic])) != nil else { return }
        try? FileManager.checked.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated static func fileName(_ key: String) -> String { "\(key).jpg" }

    /// Tab keys are `tab_<hex>` (or a local tab's id); anything else never becomes a path.
    nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// A browser page's picture from the last quit over its whole pane content area (toolbar and page), drawn at the
/// page's frame there, until the pane takes it down (the page's first content, the launch image limit, another
/// tab). It never takes a click or a key (``hitTest(_:)``), and shows nothing while the area is not the size it
/// had at the quit: a picture of another size would show the page moved or stretched (Chrome's paint preview drops
/// a capture on a size mismatch too).
public final class BrowserLaunchPictureView: NSView {
    /// The tab whose page this pictures.
    public let tab: String
    public let picture: BrowserLaunchPictures.Picture
    /// The page's pixels at the page's frame; a view, so AppKit keeps the image upright in this flipped view.
    private let pageView = NSView()
    /// The page the picture waits for, once it exists (``waits(for:)``).
    private weak var awaited: AnyObject?
    /// What ``onShowsChange`` was last told; nil: nothing yet.
    private var reported: Bool?

    /// Runs with whether the picture shows now (in a window, at its size at the quit) each time that changes, and
    /// at once when set: a page drawn in its own window over the pane keeps a hole over all of it meanwhile
    /// (`BrowserPageCovering`), so the picture is not under that window. A replaced closure that was told true is
    /// told false.
    public var onShowsChange: (@MainActor (Bool) -> Void)? {
        didSet {
            if reported == true { oldValue?(false) }
            reported = nil
            reportShows()
        }
    }

    public init(_ picture: BrowserLaunchPictures.Picture, tab: String) {
        self.tab = tab
        self.picture = picture
        super.init(frame: .zero)
        pageView.wantsLayer = true
        // The picture changes in one frame: no implicit fade or move of its layer, animations on or off.
        pageView.layer?.actions = ["contents": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        pageView.layer?.contents = picture.image
        pageView.layer?.contentsGravity = .resize
        pageView.isHidden = true
        addSubview(pageView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    /// Clicks and scrolls reach the views under the picture.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportShows()
    }

    /// Whether the picture shows now: the area has the size it had at the quit.
    public var showsPicture: Bool { !pageView.isHidden }

    /// Records `page` as the page the picture waits for; false when it already waited for it.
    public func waits(for page: AnyObject) -> Bool {
        guard awaited !== page else { return false }
        awaited = page
        return true
    }

    private func place() {
        let fits = abs(bounds.width - picture.paneSize.width) < 1 && abs(bounds.height - picture.paneSize.height) < 1
        pageView.frame = picture.pageFrame
        pageView.isHidden = !fits
        reportShows()
    }

    private func reportShows() {
        let shows = window != nil && showsPicture
        guard shows != reported, let onShowsChange else { return }
        reported = shows
        onShowsChange(shows)
    }
}
