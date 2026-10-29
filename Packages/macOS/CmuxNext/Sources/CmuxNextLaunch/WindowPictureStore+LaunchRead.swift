import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
public import CoreGraphics
public import Foundation

/// The launch's read of the front window's picture, which the first frame shows until the live
/// window is built under it. Chrome does this on Android (`StartupPaintPreview`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java): only the first
/// restored tab gets its capture, read and decoded off the UI thread before it is shown.
///
/// The launch reads only the front window's picture, `<profile>/<window>.heic` and its meta as the quit wrote them
/// (``write(_:to:encode:)``), on the files lane from the app's `main` (``prefetchFront(_:mark:)``). Which window is
/// front, and its profile, come from the daemon's launch snapshot, asked only once a profile folder holds a meta, so
/// a launch with no picture reads nothing more than the folders. The meta must name that window and profile; the
/// image is then decoded there (`LaunchFileReader.image(at:maximumBytes:)` creates it with
/// `kCGImageSourceShouldCacheImmediately`), so the main thread gets pixels ready to draw. The first frame asks with
/// ``takeFront(matching:launch:)``, the only way out of the store, so the launch rules always apply
/// (WindowPictureStore+LaunchRules.swift); it never waits. The picture is handed out once and dropped at startup
/// complete when nobody took it (``dropFront()``; a decoded window picture is tens of MB).
///
/// ```swift
/// let pictures = WindowPictureStore(state: stateDirectory, work: work)
/// pictures.prefetchFront({ frontWindow() }) { DebugTimings.markLaunch($0) }
/// order.startup.whenComplete { _ in pictures.dropFront() }
/// _ = await pictures.frontFinished()   // the first window orders in once the read has ended
/// let facts = WindowPictureStore.LaunchFacts(savedPicture: settings.snapshot.savedPicture,
///                                            recovered: crashRecovery.recovery.isRestart,
///                                            incognitoLeftovers: incognitoLedger.mayHaveLeftovers)
/// let front = pictures.takeFront(matching: openingWindowMeta, launch: facts)   // at the first window's frame
/// ```
extension WindowPictureStore {
    /// A larger picture file is not read.
    nonisolated static let maximumPictureBytes = 32 << 20
    /// A larger meta file is not read.
    nonisolated static let maximumMetaBytes = 64 << 10

    /// The window the launch shows first and the profile it shows (the folder of its picture).
    public nonisolated struct FrontWindow: Sendable, Equatable {
        /// The snapshot's window record id.
        public let window: String
        /// `WindowRecord.profile`, the default profile's id when the record names none (as `WindowState.profileID`).
        public let profile: String

        public init(window: String, profile: String) {
            (self.window, self.profile) = (window, profile)
        }
    }

    /// The front window's picture from the last quit, decoded.
    public nonisolated struct FrontPicture: Sendable {
        /// The window it pictures (the snapshot's window record id).
        public let windowID: String
        /// The window's pixels.
        public let image: CGImage
        /// What it shows, which the launch matches with the window it opens before it shows the picture
        /// (``WindowPictureMeta/mismatches(_:)``).
        public let meta: WindowPictureMeta

        public init(windowID: String, image: CGImage, meta: WindowPictureMeta) {
            (self.windowID, self.image, self.meta) = (windowID, image, meta)
        }
    }

    /// Starts reading and decoding the front window's picture on the files lane at once; a later call does nothing.
    ///
    /// - Parameters:
    ///   - front: The window the launch shows first, from the launch snapshot. It runs on the lane, only when a
    ///     profile folder holds a meta; nil reads no picture.
    ///   - mark: Records the launch marks `launch_picture_decoded` (on the lane, when the picture is decoded),
    ///     `launch_picture_missed` (the first frame asked before the read ended) and `launch_picture_dropped`
    ///     (nobody took it by startup complete).
    public func prefetchFront(_ front: @escaping @Sendable () -> FrontWindow?, mark: @escaping @Sendable (String) -> Void = { _ in }) {
        launch.start(front, mark: mark)
    }

    /// The front window's picture with no launch rule applied, at once and never waiting: nil while the read runs,
    /// when the last quit saved none of that window, or once handed out or dropped. Internal: the launch takes it
    /// only through ``takeFront(matching:launch:)``.
    func takeFront() -> FrontPicture? {
        launch.take()
    }

    /// Whether the read found a picture, once it has ended (the caller suspends; no thread waits), without handing
    /// it out: the first window orders in on it. False when there is none, or it was taken or
    /// dropped. It gives no pixels: those come only through ``takeFront(matching:launch:)``.
    @discardableResult
    public func frontFinished() async -> Bool {
        await launch.finished() != nil
    }

    /// The front window's picture once the read has ended, with no launch rule applied (tests).
    func finishedFront() async -> FrontPicture? {
        await launch.finished()
    }

    /// Drops the read's picture when nobody took it; later asks get none.
    public func dropFront() {
        launch.drop()
    }

    /// The state of the launch's one read: started once, then taken or dropped once.
    @MainActor
    final class FrontRead {
        private let directory: URL?
        private let work: BackgroundWork
        private let reader: LaunchFileReader
        /// The read; nil before it starts, once taken and once dropped.
        private var read: LaunchRead<FrontPicture?>?
        /// The read was taken or dropped: ``start(_:mark:)`` starts no new one.
        private var ended = false
        private var mark: @Sendable (String) -> Void = { _ in }

        init(directory: URL?, work: BackgroundWork, reader: LaunchFileReader) {
            (self.directory, self.work, self.reader) = (directory, work, reader)
        }

        func start(_ front: @escaping @Sendable () -> FrontWindow?, mark: @escaping @Sendable (String) -> Void) {
            guard let directory, read == nil, !ended else { return }
            self.mark = mark
            let reader = reader
            read = LaunchRead<FrontPicture?>(on: work, dropped: .some(nil)) {
                let picture = WindowPictureStore.readFront(in: directory, front: front, reader)
                if picture != nil { mark("launch_picture_decoded") }
                return picture
            }
        }

        func take() -> FrontPicture? {
            guard let read else { return nil }
            guard let result = read.value else {
                mark("launch_picture_missed")
                return nil
            }
            end()
            return result
        }

        /// Records the launch mark `name` with the read's recorder (a refusal, WindowPictureStore+LaunchRules.swift).
        func note(_ name: String) {
            mark(name)
        }

        func finished() async -> FrontPicture? {
            guard let read else { return nil }
            return await read.finished()
        }

        func drop() {
            guard !ended else { return }
            if let result = read?.value, result != nil { mark("launch_picture_dropped") }
            end()
        }

        private func end() {
            read = nil
            ended = true
        }
    }

    /// The front window's picture under `directory` (`<profile>/<window>.heic|json`), decoded: nil when no profile
    /// folder holds a meta (then `front` is not asked), when `front` names none or a window with no meta or
    /// picture in its profile's folder, when the meta names another window or profile, or when the picture does
    /// not decode.
    nonisolated static func readFront(in directory: URL, front: () -> FrontWindow?, _ reader: LaunchFileReader) -> FrontPicture? {
        let files = FileManager.checked
        func names(_ profile: String) -> [String] {
            (try? files.contentsOfDirectory(atPath: directory.appending(path: profile, directoryHint: .isDirectory).path)) ?? []
        }
        let profiles = ((try? files.contentsOfDirectory(atPath: directory.path)) ?? []).filter { isFileSafe($0) }
        guard profiles.contains(where: { profile in names(profile).contains { $0.hasSuffix(".\(metaExtension)") } }),
              let front = front(), isFileSafe(front.window), isFileSafe(front.profile), profiles.contains(front.profile) else { return nil }
        let folder = directory.appending(path: front.profile, directoryHint: .isDirectory)
        let saved = names(front.profile)
        let metaName = "\(front.window).\(metaExtension)", pictureName = "\(front.window).\(pictureExtension)"
        guard saved.contains(metaName), saved.contains(pictureName),
              let data = reader.data(at: folder.appending(path: metaName), maximumBytes: maximumMetaBytes),
              let meta = try? JSONDecoder().decode(WindowPictureMeta.self, from: data),
              meta.window == front.window, meta.profile == front.profile,
              let image = reader.image(at: folder.appending(path: pictureName), maximumBytes: maximumPictureBytes)
        else { return nil }
        return FrontPicture(windowID: front.window, image: image, meta: meta)
    }
}
