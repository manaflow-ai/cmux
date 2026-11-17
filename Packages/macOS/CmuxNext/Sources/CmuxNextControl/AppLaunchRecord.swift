public import CmuxNextWakeups
import Foundation

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

/// Debounced launch-record persistence shared by the app's window-record owner.
@MainActor
public final class AppLaunchRecord {
    private let bundleID: String?
    private let work: BackgroundWork
    private let restored: @MainActor () -> Bool
    private let socketPath: @MainActor () async -> String?
    private let snapshot: @MainActor ([String: LaunchRecordImage], String) -> LaunchRecordSnapshot
    private var images: [String: LaunchRecordImage] = [:]
    private lazy var writer: LaunchRecordWriter? = {
        guard let bundleID else { return nil }
        let url = LaunchTimesFile.supportDirectory(bundleID: bundleID)
            .appending(path: "launch-record.bin", directoryHint: .notDirectory)
        return LaunchRecordWriter(url: url, work: work) { [weak self] in
            guard let self else { return nil }
            let socket = await self.socketPath() ?? ""
            return self.snapshot(self.images, socket)
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
        images[id] = image
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
