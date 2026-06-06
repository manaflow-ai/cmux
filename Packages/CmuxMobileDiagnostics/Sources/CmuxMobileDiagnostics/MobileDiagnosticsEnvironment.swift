import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Static app/device facts that head a diagnostics report.
///
/// These are read once at report time from the bundle and OS. The values are
/// injected into ``MobileDiagnosticsReportBuilder`` so tests can pin them and
/// assert the header deterministically, rather than depending on whatever the
/// test host's bundle and device report.
public struct MobileDiagnosticsEnvironment: Sendable {
    /// App display name (`CFBundleName`).
    public let appName: String
    /// Marketing version (`CFBundleShortVersionString`, e.g. `"0.64.0"`).
    public let appVersion: String
    /// Build number (`CFBundleVersion`).
    public let buildNumber: String
    /// Bundle identifier (e.g. `"dev.cmux.ios"`).
    public let bundleID: String
    /// Device model identifier or marketing name (e.g. `"iPhone"`).
    public let deviceModel: String
    /// OS name and version (e.g. `"iOS 18.4"`).
    public let osVersion: String

    /// Creates a diagnostics environment snapshot.
    ///
    /// - Parameters:
    ///   - appName: App display name.
    ///   - appVersion: Marketing version.
    ///   - buildNumber: Build number.
    ///   - bundleID: Bundle identifier.
    ///   - deviceModel: Device model identifier or name.
    ///   - osVersion: OS name and version.
    public init(
        appName: String,
        appVersion: String,
        buildNumber: String,
        bundleID: String,
        deviceModel: String,
        osVersion: String
    ) {
        self.appName = appName
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.bundleID = bundleID
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    /// Reads the current app/device facts from the main bundle and OS.
    ///
    /// Missing bundle keys fall back to `"?"`. On non-UIKit platforms the device
    /// model and OS version come from `ProcessInfo`.
    ///
    /// - Returns: The live environment snapshot.
    @MainActor public static func current() -> MobileDiagnosticsEnvironment {
        let bundle = Bundle.main

        let deviceModel: String
        let osVersion: String
        #if canImport(UIKit)
        deviceModel = Self.hardwareModelIdentifier() ?? UIDevice.current.model
        osVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        deviceModel = Self.hardwareModelIdentifier() ?? "Mac"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #endif

        return MobileDiagnosticsEnvironment(
            appName: Self.infoString("CFBundleName", in: bundle),
            appVersion: Self.infoString("CFBundleShortVersionString", in: bundle),
            buildNumber: Self.infoString("CFBundleVersion", in: bundle),
            bundleID: bundle.bundleIdentifier ?? "?",
            deviceModel: deviceModel,
            osVersion: osVersion
        )
    }

    /// Read a string `Info.plist` value, falling back to `"?"` when missing.
    private static func infoString(_ key: String, in bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: key) as? String) ?? "?"
    }

    /// The hardware model identifier (e.g. `"iPhone16,2"`), if available.
    private static func hardwareModelIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? nil : identifier
    }
}
