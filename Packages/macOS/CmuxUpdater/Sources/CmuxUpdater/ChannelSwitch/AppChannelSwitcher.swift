public import Foundation

/// A step of an in-progress switch, reported so the UI can show progress.
public enum AppChannelSwitchPhase: Equatable, Sendable {
    /// Downloading the DMG; the completed fraction when known.
    case downloading(fractionCompleted: Double?)
    /// Mounting the DMG and checking the app's signature.
    case verifying
    /// Copying the verified app into an Applications folder.
    case installing
    /// Opening the app.
    case launching
}

/// How a switch finished.
public enum AppChannelSwitchOutcome: Equatable, Sendable {
    /// The target app was already installed at this URL and was opened.
    case openedInstalledApp(URL)
    /// The target app was downloaded, verified, installed at this URL, and opened.
    case installedAndOpened(URL)
}

/// Why a switch failed.
public enum AppChannelSwitchError: Error, Equatable, Sendable {
    /// The DMG could not be downloaded; carries the underlying description.
    case downloadFailed(String)
    /// The DMG could not be mounted; carries the underlying description.
    case mountFailed(String)
    /// The mounted DMG holds no app with the target bundle identifier.
    case appNotFoundInDiskImage
    /// The app in the DMG failed signature verification and was not installed.
    case verificationFailed(AppSignatureVerificationFailure)
    /// Something that is not the target app already sits at the install destination.
    case destinationOccupied(URL)
    /// Copying the app into place failed; carries the underlying description.
    case installFailed(String)
    /// The app could not be opened; carries the underlying description.
    case launchFailed(String)
}

/// Opens the other cmux app, downloading, verifying and installing it first when it is not
/// installed.
///
/// ```swift
/// let outcome = try await AppChannelSwitcher().switchTo(.nightly) { phase in
///     print(phase)
/// }
/// ```
///
/// Every side effect goes through an injected service, so tests drive the whole flow with fakes.
public struct AppChannelSwitcher: Sendable {
    private let locator: any InstalledAppLocating
    private let downloader: any AppChannelDownloading
    private let mounter: any DiskImageMounting
    private let inspector: any AppSignatureInspecting
    private let launcher: any AppLaunching
    private let fileSystem: any AppInstallFileSystem
    private let locations: AppChannelInstallLocations
    private let verifier: AppSignatureVerifier
    private let architecture: UpdateHostArchitecture
    private let temporaryDirectory: URL

    /// Creates a switcher. The defaults are the live macOS services.
    public init(
        locator: any InstalledAppLocating = WorkspaceInstalledAppLocator(),
        downloader: any AppChannelDownloading = URLSessionAppChannelDownloader(),
        mounter: any DiskImageMounting = HdiutilDiskImageMounter(),
        inspector: any AppSignatureInspecting = SecurityAppSignatureInspector(),
        launcher: any AppLaunching = WorkspaceAppLauncher(),
        fileSystem: any AppInstallFileSystem = FileManagerAppInstallFileSystem(),
        locations: AppChannelInstallLocations = AppChannelInstallLocations(),
        verifier: AppSignatureVerifier = AppSignatureVerifier(),
        architecture: UpdateHostArchitecture = .current,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.locator = locator
        self.downloader = downloader
        self.mounter = mounter
        self.inspector = inspector
        self.launcher = launcher
        self.fileSystem = fileSystem
        self.locations = locations
        self.verifier = verifier
        self.architecture = architecture
        self.temporaryDirectory = temporaryDirectory
    }

    /// The installed copy of `target` this switch would open, or `nil` when it would download.
    public func installedApp(for target: AppChannelSwitchTarget) -> URL? {
        locations.preferredInstalledApp(
            from: locator.applicationURLs(bundleIdentifier: target.bundleIdentifier),
            fileExists: fileSystem.fileExists(at:)
        )
    }

    /// Opens `target`, installing it first when needed.
    ///
    /// Cancelling the calling task stops the download or install; the DMG is always detached
    /// and temporary files removed. The app is copied to a hidden staging folder next to the
    /// destination and only moved into place after that copy passes ``AppSignatureVerifier``.
    ///
    /// - Parameters:
    ///   - target: The app to switch to.
    ///   - progress: Called with each phase of a download-and-install switch.
    /// - Throws: ``AppChannelSwitchError``, or `CancellationError` when cancelled.
    public func switchTo(
        _ target: AppChannelSwitchTarget,
        progress: @escaping @Sendable (AppChannelSwitchPhase) -> Void
    ) async throws -> AppChannelSwitchOutcome {
        try Task.checkCancellation()
        if let installed = installedApp(for: target) {
            try await launch(installed)
            return .openedInstalledApp(installed)
        }

        let workDirectory = temporaryDirectory
            .appendingPathComponent("cmux-app-switch-\(UUID().uuidString)", isDirectory: true)
        defer { fileSystem.removeItem(at: workDirectory) }
        let image = workDirectory.appendingPathComponent("\(target.rawValue).dmg", isDirectory: false)

        progress(.downloading(fractionCompleted: nil))
        do {
            try fileSystem.createDirectory(at: workDirectory)
            // A constant URL that fails to parse surfaces as a failed download, not a trap.
            guard let url = target.downloadURL(architecture: architecture) else { throw URLError(.badURL) }
            try await downloader.download(from: url, to: image) { fraction in
                progress(.downloading(fractionCompleted: fraction))
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw AppChannelSwitchError.downloadFailed(String(describing: error))
        }
        try Task.checkCancellation()

        progress(.verifying)
        let mountPoint: URL
        do {
            mountPoint = try await mounter.attach(image)
        } catch {
            throw AppChannelSwitchError.mountFailed(String(describing: error))
        }
        let installed: URL
        do {
            installed = try install(target, fromVolume: mountPoint, progress: progress)
        } catch {
            await mounter.detach(mountPoint)
            throw error
        }
        await mounter.detach(mountPoint)

        progress(.launching)
        try await launch(installed)
        return .installedAndOpened(installed)
    }

    private func install(
        _ target: AppChannelSwitchTarget,
        fromVolume mountPoint: URL,
        progress: @Sendable (AppChannelSwitchPhase) -> Void
    ) throws -> URL {
        guard let sourceApp = fileSystem.contentsOfDirectory(at: mountPoint).first(where: {
            $0.pathExtension == "app" && fileSystem.bundleIdentifier(ofAppAt: $0) == target.bundleIdentifier
        }) else {
            throw AppChannelSwitchError.appNotFoundInDiskImage
        }

        let destination = locations.installDestination(
            appName: sourceApp.lastPathComponent,
            isWritableDirectory: fileSystem.isWritableDirectory(_:)
        )
        let destinationExists = fileSystem.fileExists(at: destination)
        if destinationExists, fileSystem.bundleIdentifier(ofAppAt: destination) != target.bundleIdentifier {
            throw AppChannelSwitchError.destinationOccupied(destination)
        }

        // Stage next to the destination so the final move stays on one volume, and verify
        // the staged copy: that is the exact bytes that get installed.
        let stagingDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".cmux-app-switch-\(UUID().uuidString)", isDirectory: true)
        defer { fileSystem.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent(sourceApp.lastPathComponent, isDirectory: true)
        do {
            try fileSystem.createDirectory(at: stagingDirectory)
            try fileSystem.copyItem(at: sourceApp, to: staged)
        } catch {
            throw AppChannelSwitchError.installFailed(String(describing: error))
        }

        do {
            let report = try inspector.inspect(appURL: staged, teamIdentifier: verifier.teamIdentifier)
            try verifier.verify(report, bundleIdentifier: target.bundleIdentifier)
        } catch let failure as AppSignatureVerificationFailure {
            throw AppChannelSwitchError.verificationFailed(failure)
        } catch {
            throw AppChannelSwitchError.verificationFailed(.invalidSignature)
        }
        try Task.checkCancellation()

        progress(.installing)
        do {
            if destinationExists {
                try fileSystem.replaceItem(at: destination, with: staged)
            } else {
                try fileSystem.moveItem(at: staged, to: destination)
            }
        } catch {
            throw AppChannelSwitchError.installFailed(String(describing: error))
        }
        return destination
    }

    private func launch(_ appURL: URL) async throws {
        do {
            try await launcher.openApplication(at: appURL)
        } catch {
            throw AppChannelSwitchError.launchFailed(String(describing: error))
        }
    }
}
