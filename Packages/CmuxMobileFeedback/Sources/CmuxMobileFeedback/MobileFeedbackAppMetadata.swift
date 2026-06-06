#if os(iOS)
public import CmuxMobileDiagnostics
import Foundation
import UIKit

/// App and device metadata included alongside mobile feedback.
public struct MobileFeedbackAppMetadata: Sendable {
    /// User-visible app version.
    public let appVersion: String
    /// App build number.
    public let appBuild: String
    /// Source commit baked into the app, when available.
    public let appCommit: String
    /// App bundle identifier.
    public let bundleIdentifier: String
    /// Operating system version string.
    public let osVersion: String
    /// Preferred locale identifier.
    public let localeIdentifier: String
    /// Hardware model identifier.
    public let hardwareModel: String
    /// Physical memory formatted in whole GB.
    public let memoryGB: String
    /// CPU architecture string.
    public let architecture: String
    /// Display count and size summary.
    public let displayInfo: String

    /// Creates metadata from already-collected fields.
    ///
    /// - Parameters:
    ///   - appVersion: User-visible app version.
    ///   - appBuild: App build number.
    ///   - appCommit: Source commit baked into the app, when available.
    ///   - bundleIdentifier: App bundle identifier.
    ///   - osVersion: Operating system version string.
    ///   - localeIdentifier: Preferred locale identifier.
    ///   - hardwareModel: Hardware model identifier.
    ///   - memoryGB: Physical memory formatted in whole GB.
    ///   - architecture: CPU architecture string.
    ///   - displayInfo: Display count and size summary.
    public init(
        appVersion: String,
        appBuild: String,
        appCommit: String,
        bundleIdentifier: String,
        osVersion: String,
        localeIdentifier: String,
        hardwareModel: String,
        memoryGB: String,
        architecture: String,
        displayInfo: String
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.appCommit = appCommit
        self.bundleIdentifier = bundleIdentifier
        self.osVersion = osVersion
        self.localeIdentifier = localeIdentifier
        self.hardwareModel = hardwareModel
        self.memoryGB = memoryGB
        self.architecture = architecture
        self.displayInfo = displayInfo
    }

    /// Captures metadata for the currently running app and device.
    ///
    /// - Parameter environment: Diagnostics environment used for app/device facts.
    /// - Returns: Metadata ready to include in a feedback submission.
    @MainActor
    public static func current(environment: MobileDiagnosticsEnvironment = .current()) -> MobileFeedbackAppMetadata {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let commit = (infoDictionary["CMUXCommit"] as? String).flatMap { value in
            value.isEmpty ? nil : value
        } ?? env["CMUX_COMMIT"]

        return MobileFeedbackAppMetadata(
            appVersion: environment.appVersion == "?" ? "" : environment.appVersion,
            appBuild: environment.buildNumber == "?" ? "" : environment.buildNumber,
            appCommit: commit ?? "",
            bundleIdentifier: environment.bundleID == "?" ? "" : environment.bundleID,
            osVersion: environment.osVersion == "?" ? "" : environment.osVersion,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hardwareModel: environment.deviceModel == "?" ? "" : environment.deviceModel,
            memoryGB: mobileFeedbackFormatMemoryGB(),
            architecture: mobileFeedbackCurrentArchitecture(),
            displayInfo: mobileFeedbackCurrentDisplayInfo()
        )
    }
}

private func mobileFeedbackFormatMemoryGB() -> String {
    let bytes = ProcessInfo.processInfo.physicalMemory
    let gb = Double(bytes) / (1_024 * 1_024 * 1_024)
    return "\(Int(gb)) GB"
}

private func mobileFeedbackCurrentArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

@MainActor
private func mobileFeedbackCurrentDisplayInfo() -> String {
    let descriptions = UIScreen.screens.map { screen -> String in
        let bounds = screen.bounds
        let scale = screen.scale
        return "\(Int(bounds.width))x\(Int(bounds.height)) @\(Int(scale))x"
    }
    let count = UIScreen.screens.count
    let prefix = "\(count) display\(count == 1 ? "" : "s")"
    return "\(prefix), \(descriptions.joined(separator: "; "))"
}
#endif
