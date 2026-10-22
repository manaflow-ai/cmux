public import CmuxNextBrowserImport
import Foundation

/// The browsers part of `cmux browser cookie-imports`: every browser on this Mac cmux can import
/// cookies from, whether it is open now, its profiles (the `--from <browser>:<profile>` names), and
/// what the person will be asked after Allow. Built from folder names and lock files only: no
/// cookie file is opened and no process is listed, so it needs no consent.
public struct CookieSourceListing: Sendable, Equatable {
    /// One browser.
    public struct Entry: Sendable, Equatable {
        /// The `--from` name (`chrome`, `arc`, `safari`).
        public var id: String
        /// The app's name (`Google Chrome`).
        public var name: String
        /// The browser is running now (its profile lock is held), nil when cmux cannot tell (Safari).
        public var isOpen: Bool?
        /// Its profiles as `--from <id>:<profile>` takes them (shown names, else folder names).
        public var profiles: [String]
        /// cmux can read its cookies (false for a browser that keeps them in a store cmux does not read).
        public var isReadable: Bool
        /// What macOS asks after Allow: `keychain` (the browser's Safe Storage item), `fullDiskAccess` (Safari), or `none`.
        public var prompt: String
    }

    /// The browsers, open ones first, then by name.
    public var entries: [Entry]

    /// - Parameters:
    ///   - sources: What ``BrowserSourceDetector`` found.
    ///   - isOpen: Whether a browser runs now (``CookieSourceListing/lockHeld(_:)`` by default).
    public init(sources: [BrowserSource], isOpen: (BrowserSource) -> Bool? = CookieSourceListing.lockHeld) {
        entries = sources.map { source in
            let browser = source.browser
            let prompt = switch browser.family {
            case .chromium: browser.safeStorageService == nil ? "none" : "keychain"
            case .safari: "fullDiskAccess"
            default: "none"
            }
            return Entry(id: browser.rawValue, name: browser.displayName,
                         isOpen: isOpen(source),
                         profiles: source.profiles.map { $0.displayName.isEmpty ? $0.directoryName : $0.displayName },
                         isReadable: !browser.family.isPrivateStore && !browser.refusesSessionData, prompt: prompt)
        }
        .sorted { ($0.isOpen == true) != ($1.isOpen == true) ? $0.isOpen == true : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether `source` runs now, from the lock a running browser holds: Chromium's `SingletonLock`
    /// link in its data folder, Firefox's `lock` link in a profile. Nil for a browser with no such
    /// lock (Safari): cmux does not list processes to find out.
    public static func lockHeld(_ source: BrowserSource) -> Bool? {
        let manager = FileManager.default
        func exists(_ url: URL) -> Bool { (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil || manager.fileExists(atPath: url.path) }
        switch source.browser.family {
        case .chromium:
            let folders = Set(source.profiles.map { $0.path.deletingLastPathComponent() })
            return folders.contains { exists($0.appending(path: "SingletonLock")) }
        case .firefox:
            return source.profiles.contains { exists($0.path.appending(path: "lock")) }
        default:
            return nil
        }
    }

    /// One line per browser for the CLI (`chrome  Google Chrome  open  profiles: Work, Personal`).
    public var text: String {
        entries.map { entry in
            var parts = [entry.id, entry.name]
            if let open = entry.isOpen { parts.append(open ? "open" : "not open") }
            if !entry.isReadable { parts.append("cookies not readable") }
            if !entry.profiles.isEmpty { parts.append("profiles: " + entry.profiles.joined(separator: ", ")) }
            if entry.prompt == "keychain" { parts.append("asks for the Mac password (Keychain)") }
            if entry.prompt == "fullDiskAccess" { parts.append("needs Full Disk Access") }
            return parts.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// The same as JSON (`[{id, name, open, profiles, readable, prompt}]`), keys sorted.
    public var json: String {
        let list: [[String: Any]] = entries.map {
            ["id": $0.id, "name": $0.name, "open": $0.isOpen.map { $0 as Any } ?? NSNull(), "profiles": $0.profiles, "readable": $0.isReadable,
             "prompt": $0.prompt]
        }
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
