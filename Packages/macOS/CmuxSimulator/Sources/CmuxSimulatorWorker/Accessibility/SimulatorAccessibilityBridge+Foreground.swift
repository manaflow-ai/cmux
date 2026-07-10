import CmuxSimulator
import Darwin
import Foundation

// Adapted from serve-sim's AccessibilityBridge.swift at commit
// af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 under Apache License 2.0.
// Modified by cmux to return typed metadata through a correlated worker call
// and to keep all private translation objects inside the child process.

extension SimulatorAccessibilityBridge {
    func foregroundApplication() throws -> SimulatorApplicationInfo? {
        let (translation, token) = try frontmostTranslation()
        defer { removeToken(token) }
        let processIdentifier = Self.numberProperty(
            translation,
            names: ["pid", "processIdentifier", "processID"]
        )?.int32Value
        var bundleIdentifier = Self.stringProperty(
            translation,
            names: ["bundleIdentifier", "processBundleIdentifier", "applicationIdentifier"]
        )
        let bundleURL = processIdentifier.flatMap(Self.applicationBundleURL)
        let info = bundleURL.flatMap(Self.applicationInfo) ?? [:]
        if bundleIdentifier == nil { bundleIdentifier = info["CFBundleIdentifier"] as? String }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }

        return SimulatorApplicationInfo(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String),
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            minimumOSVersion: info["MinimumOSVersion"] as? String,
            isReactNative: bundleURL.map(Self.containsReactNative) ?? false,
            executable: info["CFBundleExecutable"] as? String,
            bundlePath: bundleURL?.path
        )
    }

    private static func numberProperty(_ target: NSObject, names: [String]) -> NSNumber? {
        names.lazy.compactMap { objectProperty(target, selectorName: $0) as? NSNumber }.first
    }

    private static func stringProperty(_ target: NSObject, names: [String]) -> String? {
        names.lazy.compactMap { objectProperty(target, selectorName: $0) as? String }
            .first(where: { !$0.isEmpty })
    }

    private static func applicationInfo(_ bundleURL: URL) -> [String: Any]? {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }

    private static func containsReactNative(_ bundleURL: URL) -> Bool {
        if FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("main.jsbundle").path
        ) || FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Frameworks/React.framework").path
        ) { return true }
        let frameworks = bundleURL.appendingPathComponent("Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { name in
            let value = name.lowercased()
            return value.contains("react") || value.contains("hermes") || value.contains("expo")
        }
    }

    private static func applicationBundleURL(_ processIdentifier: Int32) -> URL? {
        guard processIdentifier > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        var current = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
        for _ in 0..<10 {
            if current.pathExtension == "app" { return current }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { break }
            current = parent
        }
        return nil
    }
}
