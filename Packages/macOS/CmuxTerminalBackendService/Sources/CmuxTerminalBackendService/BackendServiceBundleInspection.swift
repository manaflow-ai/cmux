public import Foundation
internal import Darwin

/// Validates the launch-agent files embedded in an app bundle before registration.
public struct BackendServiceBundleInspection: Sendable {
    /// The app bundle being inspected.
    public let bundleURL: URL

    /// The backend identity expected inside the bundle.
    public let descriptor: BackendServiceDescriptor

    /// Creates an inspection for an app bundle.
    ///
    /// - Parameters:
    ///   - bundleURL: The app bundle root.
    ///   - descriptor: The identity whose files must be present.
    public init(
        bundleURL: URL,
        descriptor: BackendServiceDescriptor
    ) {
        self.bundleURL = bundleURL
        self.descriptor = descriptor
    }

    /// The expected launch-agent property-list URL.
    public var propertyListURL: URL {
        bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(descriptor.propertyListName, isDirectory: false)
    }

    /// The expected backend executable URL.
    public var executableURL: URL {
        bundleURL.appendingPathComponent(descriptor.executableRelativePath, isDirectory: false)
    }

    /// The renderer that must remain an exact sibling of the installed backend.
    public var rendererExecutableURL: URL {
        executableURL.deletingLastPathComponent()
            .appendingPathComponent(descriptor.rendererExecutableName, isDirectory: false)
    }

    /// The backend's packaged build-ID sidecar.
    public var backendBuildIDURL: URL {
        URL(fileURLWithPath: executableURL.path + ".build-id", isDirectory: false)
    }

    /// The renderer's packaged build-ID sidecar.
    public var rendererBuildIDURL: URL {
        URL(fileURLWithPath: rendererExecutableURL.path + ".build-id", isDirectory: false)
    }

    /// Returns the first unusable required item, or `nil` when the bundle is ready.
    ///
    /// - Returns: The first missing item in registration order.
    public func firstMissingItem() -> BackendServiceMissingBundleItem? {
        let fileManager = FileManager()
        guard fileManager.isReadableFile(atPath: propertyListURL.path) else {
            return .propertyList(propertyListURL)
        }
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            return .executable(executableURL)
        }
        guard isSafeRegularFile(executableURL, requireExecutable: true) else {
            return .invalidArtifact(executableURL)
        }
        guard fileManager.isExecutableFile(atPath: rendererExecutableURL.path) else {
            return .rendererExecutable(rendererExecutableURL)
        }
        guard isSafeRegularFile(rendererExecutableURL, requireExecutable: true) else {
            return .invalidArtifact(rendererExecutableURL)
        }
        guard fileManager.isReadableFile(atPath: backendBuildIDURL.path) else {
            return .backendBuildID(backendBuildIDURL)
        }
        guard isSafeRegularFile(backendBuildIDURL, requireExecutable: false) else {
            return .invalidArtifact(backendBuildIDURL)
        }
        guard fileManager.isReadableFile(atPath: rendererBuildIDURL.path) else {
            return .rendererBuildID(rendererBuildIDURL)
        }
        guard isSafeRegularFile(rendererBuildIDURL, requireExecutable: false) else {
            return .invalidArtifact(rendererBuildIDURL)
        }
        return nil
    }

    private func isSafeRegularFile(_ url: URL, requireExecutable: Bool) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0
        else { return false }
        return !requireExecutable || status.st_mode & S_IXUSR != 0
    }
}
