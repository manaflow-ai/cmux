public import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Release-safe app and device metadata included in a mobile diagnostics report.
public struct MobileDiagnosticsAppInfo: Sendable, Equatable {
    /// The user-visible app version from `CFBundleShortVersionString`.
    public var version: String
    /// The build number from `CFBundleVersion`.
    public var build: String
    /// The bundle identifier, useful when distinguishing beta and dev installs.
    public var bundleIdentifier: String
    /// The hardware model identifier, such as `iPhone17,2` when available.
    public var deviceModel: String
    /// The OS name and version.
    public var osVersion: String

    /// Create app and device metadata.
    ///
    /// - Parameters:
    ///   - version: The user-visible app version.
    ///   - build: The bundle build number.
    ///   - bundleIdentifier: The bundle identifier.
    ///   - deviceModel: The hardware model identifier.
    ///   - osVersion: The operating system name and version.
    public init(
        version: String,
        build: String,
        bundleIdentifier: String,
        deviceModel: String,
        osVersion: String
    ) {
        self.version = version
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    /// A concise identity stamp for report headers and structured-log exports.
    public var buildStamp: String {
        let versionPart = [version, build.isEmpty ? "" : "(\(build))"]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [versionPart, bundleIdentifier, deviceModel, osVersion]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }
}
