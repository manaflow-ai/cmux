import Foundation

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
            let profiles = ChromiumProfileList.entries(in: directory).map { entry in
                let path = directory.appending(path: entry.directoryName, directoryHint: .isDirectory)
                return BrowserSourceProfile(browser: browser, directoryName: entry.directoryName, displayName: entry.displayName,
                                            path: path, availability: Self.chromiumAvailability(path))
            }
            return profiles.isEmpty ? nil : BrowserSource(browser: browser, appURL: appURL, profiles: profiles)
        case .firefox:
            let profiles = FirefoxProfileList.entries(in: directory).map { entry in
                BrowserSourceProfile(browser: browser, directoryName: entry.directoryName, displayName: entry.displayName,
                                     path: entry.path, availability: Self.firefoxAvailability(entry.path))
            }
            return profiles.isEmpty ? nil : BrowserSource(browser: browser, appURL: appURL, profiles: profiles)
        case .safari:
            let availability = Self.safariAvailability(directory)
            let blocked = availability.values.contains(.needsFullDiskAccess)
            let profile = BrowserSourceProfile(browser: browser, directoryName: "Safari", displayName: browser.displayName,
                                               path: directory, availability: availability)
            guard blocked || !profile.importableKinds.isEmpty else { return nil }
            return BrowserSource(browser: browser, appURL: appURL, profiles: [profile], needsFullDiskAccess: blocked)
        }
    }

    static func chromiumAvailability(_ profile: URL) -> [ImportDataKind: DataAvailability] {
        func present(_ name: String) -> Bool { FileManager.default.fileExists(atPath: profile.appending(path: name).path) }
        let sessions = profile.appending(path: "Sessions")
        let hasSession = ChromiumSessionReader.latestSessionFile(in: sessions) != nil || present("Current Session")
        return [
            .bookmarks: present("Bookmarks") ? .available : .absent,
            .history: present("History") ? .available : .absent,
            .openTabs: hasSession ? .available : .absent,
            .extensions: present("Extensions") ? .available : .absent,
            .passwords: present("Login Data") ? .unsupported(.needsChromiumImporter) : .absent,
            .cookies: present("Cookies") ? .unsupported(.needsChromiumImporter) : .absent,
        ]
    }

    static func firefoxAvailability(_ profile: URL) -> [ImportDataKind: DataAvailability] {
        func present(_ name: String) -> Bool { FileManager.default.fileExists(atPath: profile.appending(path: name).path) }
        let places: DataAvailability = present("places.sqlite") ? .available : .absent
        return [
            .bookmarks: places,
            .history: places,
            .openTabs: FirefoxSessionReader.sessionFile(in: profile) != nil ? .available : .absent,
            .extensions: present("extensions.json") ? .unsupported(.notChromeExtensions) : .absent,
            .passwords: present("logins.json") ? .unsupported(.sourceEncrypted) : .absent,
            .cookies: present("cookies.sqlite") ? .unsupported(.needsChromiumImporter) : .absent,
        ]
    }

    static func safariAvailability(_ directory: URL) -> [ImportDataKind: DataAvailability] {
        func state(_ name: String) -> DataAvailability {
            switch FileAccess.probe(directory.appending(path: name)) {
            case .readable: .available
            case .denied: .needsFullDiskAccess
            case .missing: .absent
            }
        }
        return [
            .bookmarks: state("Bookmarks.plist"),
            .history: state("History.db"),
            .passwords: .unsupported(.sourceEncrypted),
        ]
    }
}
