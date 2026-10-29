public import Foundation
import CmuxNextCompat

/// ``ScreenshotEnvironment`` over this Mac: CFPreferences for unsandboxed
/// apps, the container plist for sandboxed ones, and the file system.
public nonisolated struct SystemScreenshotEnvironment: ScreenshotEnvironment {
    public let homeDirectory: URL
    public let temporaryDirectory: URL

    /// Makes the environment.
    ///
    /// - Parameters:
    ///   - homeDirectory: default: the person's home.
    ///   - temporaryDirectory: default: `NSTemporaryDirectory()`.
    public init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    public func preference(_ key: String, domain: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
            ?? containerPreferences(domain)[key] as? String
    }

    public func stringPreferences(domain: String) -> [String: String] {
        var values: [String: String] = [:]
        if let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys {
                if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String { values[key] = value }
            }
        }
        for (key, value) in containerPreferences(domain) {
            if values[key] == nil, let value = value as? String { values[key] = value }
        }
        return values
    }

    public func text(at url: URL) -> String? {
        guard let attributes = try? FileManager.checked.attributesOfItem(atPath: url.path),
              (attributes[.size] as? Int ?? 0) < 1 << 20 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.checked.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A sandboxed app's preferences, from its container (CFPreferences does not read it).
    private func containerPreferences(_ domain: String) -> [String: Any] {
        let plist = homeDirectory.appendingPathComponent("Library/Containers/\(domain)/Data/Library/Preferences/\(domain).plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return object
    }
}
