public import CmuxNextWakeups
import Foundation
import os

/// Metadata supplied by the window capture owner only after publishing the image.
public struct LaunchRecordImage: Sendable {
    public let path: String
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32

    public init(path: String, pixelWidth: UInt32, pixelHeight: UInt32) {
        self.path = path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The windows' launch images the record names, by window id. Written from any thread: a publish hands its
/// image over inside its folder lock, off the main actor (`cmux_launch_image_publish_with`), before any
/// older image is pruned; the writer's snapshot reads it on the main actor.
public nonisolated final class LaunchRecordImages: Sendable {
    private let images = OSAllocatedUnfairLock<[String: LaunchRecordImage]>(initialState: [:])

    public init() {}

    public func set(_ image: LaunchRecordImage?, forWindow id: String) {
        images.withLock { $0[id] = image }
    }

    public var all: [String: LaunchRecordImage] { images.withLock { $0 } }
}

/// Debounced launch-record persistence shared by the app's window-record owner.
@MainActor
public final class AppLaunchRecord {
    private let bundleID: String?
    private let work: BackgroundWork
    private let restored: @MainActor () -> Bool
    private let socketPath: @MainActor () async -> String?
    private let snapshot: @MainActor ([String: LaunchRecordImage], String) -> LaunchRecordSnapshot
    /// Each window's launch image (`LaunchRecordImages`): the capture's publish hands it over off the main actor.
    public nonisolated let images = LaunchRecordImages()
    private lazy var writer: LaunchRecordWriter? = {
        guard let bundleID else { return nil }
        let url = LaunchTimesFile.supportDirectory(bundleID: bundleID)
            .appending(path: "launch-record.bin", directoryHint: .notDirectory)
        return LaunchRecordWriter(url: url, work: work) { [weak self] in
            guard let self else { return nil }
            let socket = await self.socketPath() ?? ""
            return self.snapshot(self.images.all, socket)
        }
    }()

    public init(bundleID: String?, work: BackgroundWork,
                restored: @escaping @MainActor () -> Bool,
                socketPath: @escaping @MainActor () async -> String?,
                snapshot: @escaping @MainActor ([String: LaunchRecordImage], String) -> LaunchRecordSnapshot) {
        self.bundleID = bundleID
        self.work = work
        self.restored = restored
        self.socketPath = socketPath
        self.snapshot = snapshot
    }

    public func setImage(_ image: LaunchRecordImage?, forWindow id: String) {
        images.set(image, forWindow: id)
        schedule()
    }

    public func schedule() {
        guard restored() else { return }
        writer?.schedule()
    }

    public func flush() async {
        guard restored() else { return }
        await writer?.flush()
    }
}
