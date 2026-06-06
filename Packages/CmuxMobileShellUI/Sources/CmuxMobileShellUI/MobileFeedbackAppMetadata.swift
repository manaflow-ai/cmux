#if os(iOS)
import CmuxMobileDiagnostics
import Foundation
import UIKit

struct MobileFeedbackAppMetadata: Sendable {
    let appVersion: String
    let appBuild: String
    let appCommit: String
    let bundleIdentifier: String
    let osVersion: String
    let localeIdentifier: String
    let hardwareModel: String
    let memoryGB: String
    let architecture: String
    let displayInfo: String

    @MainActor
    static func current(environment: MobileDiagnosticsEnvironment = .current()) -> MobileFeedbackAppMetadata {
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
