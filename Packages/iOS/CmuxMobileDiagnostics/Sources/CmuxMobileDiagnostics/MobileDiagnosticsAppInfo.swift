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

    /// Resolve app and device metadata from the running process.
    ///
    /// - Parameter bundle: The bundle to inspect. Defaults to `Bundle.main`.
    /// - Returns: Metadata suitable for a diagnostics report.
    @MainActor
    public static func current(bundle: Bundle = .main) -> MobileDiagnosticsAppInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""
        let bundleIdentifier = bundle.bundleIdentifier ?? ""
        return MobileDiagnosticsAppInfo(
            version: version,
            build: build,
            bundleIdentifier: bundleIdentifier,
            deviceModel: deviceModel(),
            osVersion: osVersion()
        )
    }

    @MainActor
    private static func osVersion() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private static func deviceModel() -> String {
        #if canImport(Darwin)
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        #else
        return ""
        #endif
    }
}
