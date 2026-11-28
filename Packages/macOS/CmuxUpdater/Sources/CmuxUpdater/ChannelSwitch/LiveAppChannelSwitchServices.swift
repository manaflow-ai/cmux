import AppKit
public import Foundation

/// ``InstalledAppLocating`` backed by LaunchServices through `NSWorkspace`.
public struct WorkspaceInstalledAppLocator: InstalledAppLocating {
    /// Creates a locator.
    public init() {}

    public func applicationURLs(bundleIdentifier: String) -> [URL] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
    }
}

/// ``AppLaunching`` backed by `NSWorkspace.openApplication`.
public struct WorkspaceAppLauncher: AppLaunching {
    /// Creates a launcher.
    public init() {}

    public func openApplication(at appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

/// ``AppInstallFileSystem`` backed by `FileManager`.
public struct FileManagerAppInstallFileSystem: AppInstallFileSystem {
    /// Creates a file system.
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isWritableDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: directory.path)
    }

    public func createDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func replaceItem(at original: URL, with replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
    }

    public func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func contentsOfDirectory(at directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    public func bundleIdentifier(ofAppAt appURL: URL) -> String? {
        SecurityAppSignatureInspector.infoPlistBundleIdentifier(appURL: appURL)
    }
}

/// ``DiskImageMounting`` backed by `/usr/bin/hdiutil`.
public struct HdiutilDiskImageMounter: DiskImageMounting {
    /// Why attaching failed.
    public struct AttachError: Error, Equatable, Sendable {
        /// `hdiutil`'s exit status, or `-1` when it produced no mount point.
        public let status: Int32
    }

    /// Creates a mounter.
    public init() {}

    public func attach(_ image: URL) async throws -> URL {
        let result = try await Self.run(["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", image.path])
        guard result.status == 0 else { throw AttachError(status: result.status) }
        guard let mountPoint = Self.mountPoint(fromAttachPlist: result.output) else {
            // Attached but unusable: detach whatever device it created before failing.
            if let device = Self.deviceEntry(fromAttachPlist: result.output) {
                _ = try? await Self.run(["detach", "-force", device])
            }
            throw AttachError(status: -1)
        }
        return mountPoint
    }

    public func detach(_ mountPoint: URL) async {
        let result = try? await Self.run(["detach", mountPoint.path])
        if result?.status != 0 {
            _ = try? await Self.run(["detach", "-force", mountPoint.path])
        }
    }

    /// The first `mount-point` in `hdiutil attach -plist` output.
    static func mountPoint(fromAttachPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let path = entity["mount-point"] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    /// The whole-disk `dev-entry` in `hdiutil attach -plist` output (the shortest one).
    static func deviceEntry(fromAttachPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        return entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
    }

    private static func run(_ arguments: [String]) async throws -> (status: Int32, output: Data) {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }.value
    }
}

/// ``AppChannelDownloading`` backed by a `URLSession` download task.
public struct URLSessionAppChannelDownloader: AppChannelDownloading {
    /// The server answered with a non-success HTTP status.
    public struct HTTPStatusError: Error, Equatable, Sendable {
        /// The HTTP status code.
        public let statusCode: Int
    }

    /// Creates a downloader.
    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    // Justification for @unchecked Sendable: the mutable state is guarded by `lock`, and
    // URLSession calls the delegate on its own serial queue.
    private let lock = NSLock()
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?
    /// Set when the task completes before the continuation is installed (a cancel that
    /// raced the start), so ``setContinuation(_:)`` can resume it immediately.
    private var completion: Result<Void, any Error>?

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, any Error>) {
        let early: Result<Void, any Error>? = lock.withLock {
            if let completion { return completion }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        } else {
            progress(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this callback returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLSessionAppChannelDownloader.HTTPStatusError(statusCode: http.statusCode)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result): (CheckedContinuation<Void, any Error>?, Result<Void, any Error>) = lock.withLock {
            let result: Result<Void, any Error>
            if let failure = error ?? moveError {
                result = .failure(failure)
            } else {
                result = .success(())
            }
            completion = result
            let pending = self.continuation
            self.continuation = nil
            return (pending, result)
        }
        continuation?.resume(with: result)
    }
}
