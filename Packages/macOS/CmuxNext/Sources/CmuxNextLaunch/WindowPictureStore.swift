public import CmuxNextDesign
public import CmuxNextWakeups
import CmuxNextCompat
public import CoreGraphics
public import Foundation

/// The windows' pictures from the last quit, one per window (p08-startup-057 writes them), and the launch's read of
/// the front window's (p08-startup-058), which the first frame shows until the live window is built under it
/// (p08-startup-059). Chrome does this on Android (`StartupPaintPreview`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java): only the first
/// restored tab gets its capture, read and decoded off the UI thread before it is shown.
///
/// A window's picture is `<window id>.heic` beside its meta `<window id>.json` (`WindowPictureMeta` decodes it),
/// in `window-pictures` of the tag's state directory. The save writes the meta last, so a quit that ends between
/// the two leaves a picture the launch never reads.
///
/// The launch reads only the front window's picture, on the files lane from the app's `main`
/// (``prefetchFront(_:mark:)``): which window that is comes from the daemon's launch snapshot (the window order
/// it saved), asked only once the folder holds a picture, so a launch with no picture reads nothing more than the
/// folder. The image is decoded there (`LaunchFileReader.image(at:maximumBytes:)` creates it with
/// `kCGImageSourceShouldCacheImmediately`), so the main thread gets pixels ready to draw. The first frame asks with
/// ``takeFront()`` and never waits; the picture is handed out once and dropped at startup complete when nobody took
/// it (``drop()``; a decoded window picture is tens of MB).
///
/// ```swift
/// let pictures = WindowPictureStore(state: stateDirectory, work: work)
/// pictures.prefetchFront({ frontWindowID() }) { DebugTimings.markLaunch($0) }
/// order.startup.whenComplete { _ in pictures.drop() }
/// let front = pictures.takeFront()   // at the first window's frame
/// ```
@MainActor
public final class WindowPictureStore {
    /// The folder of the saved pictures in the tag's state directory.
    public static let directoryName = "window-pictures"
    /// A larger picture file is not read.
    nonisolated static let maximumBytes = 32 << 20
    /// A larger meta file is not read.
    nonisolated static let maximumMetaBytes = 64 << 10
    nonisolated static let pictureExtension = "heic"
    nonisolated static let metaExtension = "json"

    /// The front window's picture from the last quit, decoded.
    public nonisolated struct FrontPicture: Sendable {
        /// The window it pictures (the snapshot's window record id).
        public let windowID: String
        /// The window's pixels.
        public let image: CGImage
        /// The meta file's bytes as the quit wrote them, which the launch matches before it shows the picture.
        public let meta: Data

        public init(windowID: String, image: CGImage, meta: Data) {
            (self.windowID, self.image, self.meta) = (windowID, image, meta)
        }
    }

    let directory: URL?
    private let work: BackgroundWork
    private let reader: LaunchFileReader
    /// The launch read of the front picture; nil before it starts, once taken and once dropped.
    private var read: LaunchRead<FrontPicture?>?
    /// The read was taken or dropped: ``prefetchFront(_:mark:)`` starts no new one.
    private var ended = false
    private var mark: @Sendable (String) -> Void = { _ in }

    /// - Parameters:
    ///   - directory: The saved pictures' folder; nil keeps none and reads none.
    ///   - work: The app's blocking-work lanes: the read and decode run on its files lane.
    ///   - reader: Reads the files; default from disk (tests record where it runs, or hold it).
    public init(directory: URL?, work: BackgroundWork, reader: LaunchFileReader = LaunchFileReader()) {
        self.directory = directory
        self.work = work
        self.reader = reader
    }

    /// The pictures in `state`, the tag's state directory (beside its launch snapshot).
    public convenience init(state: URL?, work: BackgroundWork) {
        self.init(directory: state?.appending(path: Self.directoryName, directoryHint: .isDirectory), work: work)
    }

    /// Starts reading and decoding the front window's picture on the files lane at once; a later call does nothing.
    ///
    /// - Parameters:
    ///   - front: The id of the window the launch shows first, from the launch snapshot's window order. It runs on
    ///     the lane, only when the folder holds a picture; nil reads no picture.
    ///   - mark: Records the launch marks `launch_picture_decoded` (on the lane, when the picture is decoded),
    ///     `launch_picture_missed` (the first frame asked before the read ended) and `launch_picture_dropped`
    ///     (nobody took it by startup complete).
    public func prefetchFront(_ front: @escaping @Sendable () -> String?, mark: @escaping @Sendable (String) -> Void = { _ in }) {
        guard let directory, read == nil, !ended else { return }
        self.mark = mark
        let reader = reader
        read = LaunchRead<FrontPicture?>(on: work, dropped: .some(nil)) {
            let picture = Self.readFront(in: directory, front: front, reader)
            if picture != nil { mark("launch_picture_decoded") }
            return picture
        }
    }

    /// The front window's picture, at once and never waiting: nil while the read runs (the window shows what it
    /// shows with no picture), when the last quit saved none of that window, or once handed out or dropped.
    public func takeFront() -> FrontPicture? {
        guard let read else { return nil }
        guard let result = read.value else {
            mark("launch_picture_missed")
            return nil
        }
        end()
        return result
    }

    /// The front window's picture once the read has ended (the caller suspends; no thread waits), without
    /// handing it out: the first window orders in on it (p08-startup-059). Nil when there is none, or it was
    /// taken or dropped.
    public func frontFinished() async -> FrontPicture? {
        guard let read else { return nil }
        return await read.finished()
    }

    /// Drops the read's picture when nobody took it; later asks get none.
    public func drop() {
        guard !ended else { return }
        if let result = read?.value, result != nil { mark("launch_picture_dropped") }
        end()
    }

    private func end() {
        read = nil
        ended = true
    }

    /// The front window's picture under `directory`, decoded: nil when the folder holds no picture (then `front`
    /// is not asked), when `front` names none or a window with no meta or picture, or when the picture does not
    /// decode.
    nonisolated static func readFront(in directory: URL, front: () -> String?, _ reader: LaunchFileReader) -> FrontPicture? {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        guard names.contains(where: { $0.hasSuffix(".\(metaExtension)") }),
              let windowID = front(), isFileSafe(windowID), names.contains(metaName(windowID)), names.contains(pictureName(windowID)),
              let meta = reader.data(at: directory.appending(path: metaName(windowID)), maximumBytes: maximumMetaBytes),
              let image = reader.image(at: directory.appending(path: pictureName(windowID)), maximumBytes: maximumBytes)
        else { return nil }
        return FrontPicture(windowID: windowID, image: image, meta: meta)
    }

    nonisolated static func pictureName(_ windowID: String) -> String { "\(windowID).\(pictureExtension)" }
    nonisolated static func metaName(_ windowID: String) -> String { "\(windowID).\(metaExtension)" }

    /// Window ids are lowercase UUIDs; anything else never becomes a path.
    nonisolated static func isFileSafe(_ windowID: String) -> Bool {
        !windowID.isEmpty && windowID.count <= 128
            && windowID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
