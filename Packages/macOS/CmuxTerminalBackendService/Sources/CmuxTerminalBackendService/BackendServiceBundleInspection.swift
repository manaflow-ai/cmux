public import Foundation

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
        return nil
    }
}
