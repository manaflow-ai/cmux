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
        let attachment = DiskImageAttachment(plist: result.output)
        guard let mountPoint = attachment.mountPoint else {
            // Attached but unusable: detach whatever device it created before failing.
            if let device = attachment.deviceEntry {
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

/// ``DiskImageMounting`` for a zip (cmux NEXT DEV's archive): `attach` extracts it with
/// `ditto` into a folder beside it, which keeps symlinks and the code signature intact, and
/// `detach` removes that folder.
public struct DittoZipArchiveOpener: DiskImageMounting {
    /// Why extracting failed.
    public struct ExtractError: Error, Equatable, Sendable {
        /// `ditto`'s exit status.
        public let status: Int32
    }

    /// Creates an opener.
    public init() {}

    public func attach(_ image: URL) async throws -> URL {
        let folder = image.deletingPathExtension().appendingPathExtension("contents")
        let status = try await Task.detached(priority: .userInitiated) { () throws -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", image.path, folder.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw ExtractError(status: status)
        }
        return folder
    }

    public func detach(_ mountPoint: URL) async {
        try? FileManager.default.removeItem(at: mountPoint)
    }
}

extension AppChannelSwitcher {
    /// Creates a switcher. The defaults are the live macOS services.
    public init(
        locator: any InstalledAppLocating = WorkspaceInstalledAppLocator(),
        downloader: any AppChannelDownloading = URLSessionAppChannelDownloader(),
        mounter: any DiskImageMounting = HdiutilDiskImageMounter(),
        zipOpener: any DiskImageMounting = DittoZipArchiveOpener(),
        inspector: any AppSignatureInspecting = SecurityAppSignatureInspector(),
        launcher: any AppLaunching = WorkspaceAppLauncher(),
        fileSystem: any AppInstallFileSystem = FileManagerAppInstallFileSystem(),
        locations: AppChannelInstallLocations = AppChannelInstallLocations(),
        verifier: AppSignatureVerifier = AppSignatureVerifier(),
        architecture: UpdateHostArchitecture = .current,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(
            installedAppLocator: locator,
            downloader: downloader,
            mounter: mounter,
            zipOpener: zipOpener,
            inspector: inspector,
            launcher: launcher,
            fileSystem: fileSystem,
            locations: locations,
            verifier: verifier,
            architecture: architecture,
            temporaryDirectory: temporaryDirectory
        )
    }
}
