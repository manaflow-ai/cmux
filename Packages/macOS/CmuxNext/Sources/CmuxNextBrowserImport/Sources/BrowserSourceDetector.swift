public import Foundation

/// Finds installed browsers and their profiles, and what each profile can
/// import. Reads only folder listings, `Local State` and `profiles.ini`; no
/// browsing data. Runs off the main thread (it touches the file system).
public struct BrowserSourceDetector: Sendable {
    public var environment: ImportEnvironment

    public init(environment: ImportEnvironment) {
        self.environment = environment
    }

    public func detect(_ browsers: [ImportBrowser] = ImportBrowser.allCases) -> [BrowserSource] {
        browsers.compactMap(detect)
    }

    public func detect(_ browser: ImportBrowser) -> BrowserSource? {
        let directory = environment.dataDirectory(browser)
        let appURL = browser.bundleIDs.lazy.compactMap(environment.locateApp).first
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        switch browser.family {
        case .chromium:
            let entries = browser.profileIsDataDirectory
                ? [ChromiumProfileList.Entry(directoryName: "", displayName: browser.displayName)]
                : ChromiumProfileList().entries(in: directory)
            let profiles = entries.map { entry in
                let path = entry.directoryName.isEmpty ? directory : directory.appending(path: entry.directoryName, directoryHint: .isDirectory)
                let avatar = entry.avatarFileName.map { path.appending(path: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                return BrowserSourceProfile(browser: browser, directoryName: entry.directoryName, displayName: entry.displayName,
                                            path: path, availability: Self.chromiumAvailability(path), avatar: avatar)
            }
            return profiles.isEmpty ? nil : BrowserSource(browser: browser, appURL: appURL, profiles: profiles)
        case .firefox:
            let profiles = FirefoxProfileList().entries(in: directory).map { entry in
                BrowserSourceProfile(browser: browser, directoryName: entry.directoryName, displayName: entry.displayName,
                                     path: entry.path, availability: Self.firefoxAvailability(entry.path, browser: browser))
            }
            return profiles.isEmpty ? nil : BrowserSource(browser: browser, appURL: appURL, profiles: profiles)
        case .safari:
            let cookies = browser.safariCookieFile.map { environment.homeDirectory.appending(path: $0) }
            let availability = Self.safariAvailability(directory, cookies: cookies)
            let blocked = availability.values.contains(.needsFullDiskAccess)
            let profile = BrowserSourceProfile(browser: browser, directoryName: "Safari", displayName: browser.displayName,
                                               path: directory, availability: availability)
            guard blocked || !profile.importableKinds.isEmpty else { return nil }
            return BrowserSource(browser: browser, appURL: appURL, profiles: [profile], needsFullDiskAccess: blocked)
        case .webkit:
            // Listed so the user sees why nothing moves; their own export is the path.
            let reason: UnsupportedReason = browser == .duckDuckGo ? .exportFromSource : .unknownFormat
            let profile = BrowserSourceProfile(browser: browser, directoryName: "Default", displayName: browser.displayName, path: directory,
                                               availability: [.bookmarks: .unsupported(reason), .history: .unsupported(reason),
                                                              .cookies: .unsupported(reason), .passwords: .unsupported(.exportFromSource)])
            return BrowserSource(browser: browser, appURL: appURL, profiles: [profile])
        }
    }

    /// The cookie database of a Chromium profile (`Network/Cookies` since
    /// Chromium 96, `Cookies` before).
    public static func chromiumCookieFile(_ profile: URL) -> URL? {
        for name in ["Network/Cookies", "Cookies"] {
            let url = profile.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func chromiumAvailability(_ profile: URL) -> [ImportDataKind: DataAvailability] {
        func present(_ name: String) -> Bool { FileManager.default.fileExists(atPath: profile.appending(path: name).path) }
        let sessions = profile.appending(path: "Sessions")
        let hasSession = ChromiumSessionReader().latestSessionFile(in: sessions) != nil || present("Current Session")
        return [
            .bookmarks: present("Bookmarks") ? .available : .absent,
            .history: present("History") ? .available : .absent,
            .openTabs: hasSession ? .available : .absent,
            .extensions: present("Extensions") ? .available : .absent,
            // Read only after the consent step (PasswordImporter).
            .passwords: present("Login Data") ? .available : .absent,
            .cookies: chromiumCookieFile(profile) != nil ? .available : .absent,
        ]
    }

    static func firefoxAvailability(_ profile: URL, browser: ImportBrowser) -> [ImportDataKind: DataAvailability] {
        func present(_ name: String) -> Bool { FileManager.default.fileExists(atPath: profile.appending(path: name).path) }
        let places: DataAvailability = present("places.sqlite") ? .available : .absent
        let refuse = browser.refusesSessionData
        func session(_ value: DataAvailability) -> DataAvailability {
            refuse && value != .absent ? .unsupported(.refusedForPrivacy) : value
        }
        return [
            .bookmarks: places,
            .history: session(places),
            .openTabs: session(FirefoxSessionReader().sessionFile(in: profile) != nil ? .available : .absent),
            .extensions: present("extensions.json") ? .unsupported(.notChromeExtensions) : .absent,
            .passwords: present("logins.json") ? .unsupported(.exportFromSource) : .absent,
            .cookies: session(present("cookies.sqlite") ? .available : .absent),
        ]
    }

    static func safariAvailability(_ directory: URL, cookies: URL?) -> [ImportDataKind: DataAvailability] {
        func state(_ url: URL) -> DataAvailability {
            switch FileAccess.probe(url) {
            case .readable: .available
            case .denied: .needsFullDiskAccess
            case .missing: .absent
            }
        }
        return [
            .bookmarks: state(directory.appending(path: "Bookmarks.plist")),
            .history: state(directory.appending(path: "History.db")),
            .cookies: cookies.map(state) ?? .absent,
            .passwords: .unsupported(.exportFromSource),
        ]
    }
}
