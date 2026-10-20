import AppKit
import Foundation

/// Host/app environment metadata attached to every feedback submission so the
/// founders can triage by version, OS, hardware, and display configuration.
struct FeedbackComposerAppMetadata {
    let appVersion: String
    let appBuild: String
    let appCommit: String
    let bundleIdentifier: String
    let osVersion: String
    let localeIdentifier: String
    let hardwareModel: String
    let chip: String
    let memoryGB: String
    let architecture: String
    let displayInfo: String

    static var current: FeedbackComposerAppMetadata {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let commit = (infoDictionary["CMUXCommit"] as? String).flatMap { value in
            value.isEmpty ? nil : value
        } ?? env["CMUX_COMMIT"]

        return FeedbackComposerAppMetadata(
            appVersion: infoDictionary["CFBundleShortVersionString"] as? String ?? "",
            appBuild: infoDictionary["CFBundleVersion"] as? String ?? "",
            appCommit: commit ?? "",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hardwareModel: sysctlString("hw.model") ?? "",
            chip: sysctlString("machdep.cpu.brand_string") ?? "",
            memoryGB: formatMemoryGB(),
            architecture: currentArchitecture(),
            displayInfo: currentDisplayInfo()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMemoryGB() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return "\(Int(gb)) GB"
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func currentDisplayInfo() -> String {
        let screens = NSScreen.screens
        let descriptions = screens.map { screen -> String in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return "\(Int(frame.width))x\(Int(frame.height)) @\(Int(scale))x"
        }
        let count = screens.count
        let prefix = "\(count) display\(count == 1 ? "" : "s")"
        return "\(prefix), \(descriptions.joined(separator: "; "))"
    }
}
