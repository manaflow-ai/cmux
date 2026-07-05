public import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Resolves release-safe app and device metadata from a bundle and the host process.
public struct MobileDiagnosticsAppInfoResolver {
    private let bundle: Bundle

    /// Create an app-info resolver.
    ///
    /// - Parameter bundle: The bundle to inspect. Defaults to `Bundle.main`.
    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Resolve app and device metadata from the running process.
    ///
    /// - Returns: Metadata suitable for a diagnostics report.
    @MainActor
    public func current() -> MobileDiagnosticsAppInfo {
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
    private func osVersion() -> String {
        #if canImport(UIKit)
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private func deviceModel() -> String {
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
