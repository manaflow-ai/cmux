import CmuxNextWakeups
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

/// The app supplies live state; the adapter owns persistence and never reads launch files.
@MainActor
public protocol LaunchRecordHost: AnyObject {
    var launchRecordBundleID: String? { get }
    var launchRecordWork: BackgroundWork { get }
    var launchRecordRestored: Bool { get }
    var launchRecordSocketPath: String? { get async }
    func launchRecordSnapshot(images: [String: LaunchRecordImage], socketPath: String) -> LaunchRecordSnapshot
}

/// Debounced launch-record persistence shared by the app's window-record owner.
@MainActor
public final class AppLaunchRecord {
    private weak var host: (any LaunchRecordHost)?
    private var images: [String: LaunchRecordImage] = [:]
    private lazy var writer: LaunchRecordWriter? = {
        guard let host, let bundleID = host.launchRecordBundleID else { return nil }
        let url = LaunchTimesFile.supportDirectory(bundleID: bundleID)
            .appending(path: "launch-record.bin", directoryHint: .notDirectory)
        return LaunchRecordWriter(url: url, work: host.launchRecordWork) { [weak self] in
            guard let self, let host = self.host else { return nil }
            let socket = await host.launchRecordSocketPath ?? ""
            return host.launchRecordSnapshot(images: self.images, socketPath: socket)
        }
    }()

    public init(host: any LaunchRecordHost) { self.host = host }

    public func setImage(_ image: LaunchRecordImage?, forWindow id: String) {
        images[id] = image
        schedule()
    }

    public func schedule() {
        guard let host, host.launchRecordRestored else { return }
        writer?.schedule()
    }

    public func flush() async {
        guard let host, host.launchRecordRestored else { return }
        await writer?.flush()
    }
}
