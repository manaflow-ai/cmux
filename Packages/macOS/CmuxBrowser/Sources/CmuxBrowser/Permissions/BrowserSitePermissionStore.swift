public import Foundation

/// The person's remembered permission answers for one browser profile:
/// "Allow while visiting the site" / "Allow" store allow, "Never allow" /
/// "Block" store block, and "Allow this time" stores nothing. Keyed by origin
/// (`scheme://host[:port]`) and permission kind.
///
/// Persisted as a small JSON file inside the profile's own store, so deleting
/// or clearing the profile removes it with the rest of the profile's data.
@MainActor
public final class BrowserSitePermissionStore {
    /// A remembered answer.
    public enum Setting: String, Codable, Sendable {
        case allow
        case block
    }

    /// File name inside the profile's store directory.
    public static let fileName = "cmux-site-permissions.json"

    private let fileURL: URL?
    private var settings: [String: [String: Setting]]

    /// Creates a store.
    /// - Parameter fileURL: The JSON file; `nil` keeps answers in memory only.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: Setting]].self, from: data) {
            settings = decoded
        } else {
            settings = [:]
        }
    }

    /// The origin key of a page URL: `scheme://host[:port]`, lowercased, for
    /// http and https only (`nil` otherwise: nothing is remembered for it).
    public nonisolated static func originKey(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if let port = url.port, port != (scheme == "https" ? 443 : 80) {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// The stable name of a kind in the file.
    public nonisolated static func kindKey(_ kind: BrowserPagePermissionRequest.Kind) -> String {
        switch kind {
        case .camera: "camera"
        case .microphone: "microphone"
        case .screenCapture: "screenCapture"
        case .geolocation: "geolocation"
        case .notifications: "notifications"
        case .clipboardRead: "clipboardRead"
        case .midiSysex: "midiSysex"
        case .other(let name): "other:\(name)"
        }
    }

    /// The remembered answer for `kind` at `origin`, if any.
    public func setting(_ kind: BrowserPagePermissionRequest.Kind, for origin: URL?) -> Setting? {
        guard let key = Self.originKey(for: origin) else { return nil }
        return settings[key]?[Self.kindKey(kind)]
    }

    /// Remembers an answer for each kind at `origin` (ignored for an origin
    /// that has no key).
    public func set(_ setting: Setting, for kinds: [BrowserPagePermissionRequest.Kind], at origin: URL?) {
        guard let key = Self.originKey(for: origin), !kinds.isEmpty else { return }
        var site = settings[key] ?? [:]
        for kind in kinds {
            site[Self.kindKey(kind)] = setting
        }
        settings[key] = site
        save()
    }

    /// Forgets every answer for `origin`, or every answer when `origin` is `nil`.
    public func reset(origin: URL? = nil) {
        if let origin {
            guard let key = Self.originKey(for: origin), settings.removeValue(forKey: key) != nil else { return }
        } else {
            guard !settings.isEmpty else { return }
            settings.removeAll()
        }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        if settings.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
