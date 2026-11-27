import CmuxNextCompat
public import CoreGraphics
public import Foundation
import ImageIO

/// Reads a file the last quit saved for this launch (a pane's last frame, a chat's composer state) whole.
///
/// Each read from disk is a checked blocking call (`Data(blockingContentsOf:)`), so the blocking detector
/// reports one on the main thread: run it off the main thread (on `BackgroundWork`'s `.files` lane) and hand
/// the main thread the result. A file larger than the cap is not read. ``image(at:maximumBytes:)`` also decodes
/// the image there, so the main thread gets pixels ready to draw.
///
/// Tests pass their own `read` (``init(read:)``): one that records `Thread.isMainThread`, or holds the read
/// until the test lets it go.
///
/// ```swift
/// let reader = LaunchFileReader()
/// let frame = try await work.run(.userBlocking, mayBlock: .files) { reader.image(at: url, maximumBytes: 16 << 20) }
/// ```
public nonisolated struct LaunchFileReader: Sendable {
    private let read: @Sendable (URL, Int) -> Data?

    /// A reader of the files on disk.
    public init() {
        self.init(read: { url, maximumBytes in Self.fromDisk(url, maximumBytes: maximumBytes) })
    }

    /// A reader that reads through `read`.
    ///
    /// - Parameter read: Returns the bytes of the file at the URL when it holds at most the given number
    ///   of bytes, else nil. It runs on the thread that calls ``data(at:maximumBytes:)``.
    public init(read: @escaping @Sendable (URL, Int) -> Data?) {
        self.read = read
    }

    /// The bytes of the file at `url`.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - maximumBytes: The largest file that is read.
    /// - Returns: The bytes; nil when the file is missing, unreadable or larger than `maximumBytes`.
    public func data(at url: URL, maximumBytes: Int) -> Data? {
        read(url, maximumBytes)
    }

    /// The image in the file at `url` (a PNG or a JPEG), decoded now, not at its first draw.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - maximumBytes: The largest file that is read.
    /// - Returns: The image; nil when the file is missing, larger than `maximumBytes` or not an image.
    public func image(at url: URL, maximumBytes: Int) -> CGImage? {
        guard let data = data(at: url, maximumBytes: maximumBytes),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The file's bytes from disk when it holds at most `maximumBytes`.
    private static func fromDisk(_ url: URL, maximumBytes: Int) -> Data? {
        guard let size = (try? url.blockingResourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumBytes else { return nil }
        return try? Data(blockingContentsOf: url)
    }
}
