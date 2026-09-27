import CmuxSimulator
import Foundation

// Adapted from serve-sim's AccessibilityBridge.swift at commit
// af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 under Apache License 2.0.
// Modified by cmux to return typed metadata through a correlated worker call
// and to keep all private translation objects inside the child process.

extension SimulatorAccessibilityBridge {
    func foregroundApplication() throws -> SimulatorApplicationInfo? {
        let (translation, _) = try frontmostTranslation()
        let processIdentifier = simulatorNumberProperty(
            translation,
            names: ["pid", "processIdentifier", "processID"]
        )?.int32Value
        var bundleIdentifier = simulatorStringProperty(
            translation,
            names: ["bundleIdentifier", "processBundleIdentifier", "applicationIdentifier"]
        )
        let bundleURL = processIdentifier.flatMap(applicationMetadataResolver.bundleURL)
        let info = bundleURL.flatMap(applicationMetadataResolver.info) ?? [:]
        if bundleIdentifier == nil { bundleIdentifier = info["CFBundleIdentifier"] as? String }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }

        return SimulatorApplicationInfo(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String),
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            isReactNative: bundleURL.map(applicationMetadataResolver.containsReactNative) ?? false,
            executable: info["CFBundleExecutable"] as? String,
            bundlePath: bundleURL?.path
        )
    }

}

private func simulatorNumberProperty(_ target: NSObject, names: [String]) -> NSNumber? {
    names.lazy.compactMap { objectProperty(target, selectorName: $0) as? NSNumber }.first
}

private func simulatorStringProperty(_ target: NSObject, names: [String]) -> String? {
    names.lazy.compactMap { objectProperty(target, selectorName: $0) as? String }
        .first(where: { !$0.isEmpty })
}
