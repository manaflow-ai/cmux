import AppKit
import CryptoKit
import Foundation

/// Reads extension action metadata from CEFKit's writable staged directories.
struct CEFExtensionActionLoader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(from stagedDirectories: [URL]) -> [CEFExtensionAction] {
        stagedDirectories.compactMap(loadExtension).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func loadExtension(from directory: URL) -> CEFExtensionAction? {
        guard let manifest = jsonObject(at: directory.appendingPathComponent("manifest.json")),
              let popupPath = popupPath(in: manifest) else { return nil }

        let extensionID = unpackedExtensionID(
            manifestKey: manifest["key"] as? String,
            directory: directory
        )
        guard let popupURL = URL(
            string: "chrome-extension://\(extensionID)/\(popupPath)"
        ) else { return nil }

        let rawName = manifest["name"] as? String ?? directory.lastPathComponent
        let name = localizedName(
            rawName,
            defaultLocale: manifest["default_locale"] as? String,
            directory: directory
        )
        let icon = iconPath(in: manifest).flatMap {
            templateImage(at: directory.appendingPathComponent($0))
        }
        return CEFExtensionAction(id: extensionID, name: name, icon: icon, popupURL: popupURL)
    }

    private func popupPath(in manifest: [String: Any]) -> String? {
        let action = manifest["action"] as? [String: Any]
        let browserAction = manifest["browser_action"] as? [String: Any]
        let raw = (action?["default_popup"] as? String)
            ?? (browserAction?["default_popup"] as? String)
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty ? nil : normalized
    }

    private func iconPath(in manifest: [String: Any]) -> String? {
        let action = manifest["action"] as? [String: Any]
        let browserAction = manifest["browser_action"] as? [String: Any]
        return largestIconPath(action?["default_icon"])
            ?? largestIconPath(browserAction?["default_icon"])
            ?? largestIconPath(manifest["icons"])
    }

    private func largestIconPath(_ value: Any?) -> String? {
        if let path = value as? String { return path }
        guard let entries = value as? [String: Any] else { return nil }
        return entries.compactMap { key, value -> (size: Int, path: String)? in
            guard let size = Int(key), let path = value as? String else { return nil }
            return (size, path)
        }
        .max { $0.size < $1.size }?
        .path
    }

    private func localizedName(
        _ rawName: String,
        defaultLocale: String?,
        directory: URL
    ) -> String {
        guard rawName.hasPrefix("__MSG_"), rawName.hasSuffix("__") else {
            return rawName
        }
        let key = String(rawName.dropFirst(6).dropLast(2))
        guard let defaultLocale,
              let messages = jsonObject(
                at: directory
                    .appendingPathComponent("_locales", isDirectory: true)
                    .appendingPathComponent(defaultLocale, isDirectory: true)
                    .appendingPathComponent("messages.json")
              ),
              let entry = messages[key] as? [String: Any],
              let message = entry["message"] as? String,
              !message.isEmpty else {
            return directory.lastPathComponent
        }
        return message
    }

    private func unpackedExtensionID(manifestKey: String?, directory: URL) -> String {
        let source: Data
        if let manifestKey,
           let publicKey = Data(base64Encoded: manifestKey, options: .ignoreUnknownCharacters),
           !publicKey.isEmpty {
            source = publicKey
        } else {
            let path = directory.absoluteURL.standardizedFileURL.path
            source = Data(path.utf8)
        }
        let digest = SHA256.hash(data: source)
        let alphabet = Array("abcdefghijklmnop")
        var result = ""
        result.reserveCapacity(32)
        for byte in digest.prefix(16) {
            result.append(alphabet[Int(byte >> 4)])
            result.append(alphabet[Int(byte & 0x0f)])
        }
        return result
    }

    private func templateImage(at url: URL) -> NSImage? {
        guard fileManager.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              let copy = image.copy() as? NSImage else { return nil }
        copy.isTemplate = true
        return copy
    }

    private func jsonObject(at url: URL) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }
}
