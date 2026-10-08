public import Foundation

/// Finds installed browsers and their profiles, and what each profile can
/// import. Reads only folder listings, `Local State` and `profiles.ini`; no
/// browsing data. Runs off the main thread (it touches the file system).
public struct BrowserSourceDetector: Sendable {
    public var environment: ImportEnvironment

    public init(environment: ImportEnvironment) {
        self.environment = environment
    }

    /// Each found browser once; a profile folder that two rows share
    /// (ungoogled-chromium and Chromium, Zen and Zen Twilight) is listed
    /// only under the first row.
    public func detect(_ browsers: [ImportBrowser] = ImportBrowser.allCases) -> [BrowserSource] {
        var seen = Set<String>()
        return browsers.compactMap { browser in
            guard var source = detect(browser) else { return nil }
            source.profiles = source.profiles.filter { seen.insert($0.path.standardizedFileURL.path).inserted }
            return source.profiles.isEmpty ? nil : source
        }
    }

    public func detect(_ browser: ImportBrowser) -> BrowserSource? {
        guard var source = detectFiles(browser) else { return nil }
        // Kinds the registry marks unreadable for this browser.
        let unsupported = Set((browser.row?.unsupportedKinds ?? []).compactMap(ImportDataKind.init(rawValue:)))
        guard !unsupported.isEmpty else { return source }
        for index in source.profiles.indices {
            for kind in unsupported where source.profiles[index].availability[kind] != nil && source.profiles[index].availability[kind] != .absent {
                source.profiles[index].availability[kind] = .unsupported(.exportFromSource)
            }
        }
        return source
    }

    private func detectFiles(_ browser: ImportBrowser) -> BrowserSource? {
        guard browser.row != nil else { return nil }
        let directory = environment.dataDirectory(browser)
        let appURL = browser.bundleIDs.lazy.compactMap(environment.locateApp).first
            ?? browser.appNames.lazy.compactMap(environment.locateAppNamed).first
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        switch browser.family {
        case .chromium:
            let entries = browser.profileIsDataDirectory ? Self.rootProfileEntries(directory, browser: browser) : ChromiumProfileList().entries(in: directory)
            let profiles = entries.map { entry in
                let path = entry.directoryName.isEmpty ? directory : directory.appending(path: entry.directoryName, directoryHint: .isDirectory)
                let avatar = entry.avatarFileName.map { path.appending(path: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                var availability = Self.chromiumAvailability(path, browser: browser)
                if browser.bookmarksFormat == .noStore || browser.bookmarksFormat == .htmlExport {
                    availability[.bookmarks] = .absent
                }
                if browser.safeStorageService == nil {
                    // No known Keychain item: the encrypted kinds cannot be read.
                    for kind in [ImportDataKind.passwords, .cookies] where availability[kind] == .available {
                        availability[kind] = .unsupported(.sourceEncrypted)
                    }
                }
                var bookmarksFile: URL?
                if browser.bookmarksFormat == .arcSidebar, let sidebar = browser.row?.sidebarFile.map(environment.file),
                   FileManager.default.fileExists(atPath: sidebar.path) {
                    availability[.bookmarks] = .available
                    bookmarksFile = sidebar
                }
                return BrowserSourceProfile(browser: browser, directoryName: entry.directoryName, displayName: entry.displayName,
                                            path: path, availability: availability, avatar: avatar, bookmarksFile: bookmarksFile)
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
        case .webkit, .other:
            // Listed so the user sees why nothing moves; their own HTML export is the path.
            let reason: UnsupportedReason = browser.bookmarksFormat == .htmlExport ? .exportFromSource : .unknownFormat
            let profile = BrowserSourceProfile(browser: browser, directoryName: "Default", displayName: browser.displayName, path: directory,
                                               availability: [.bookmarks: .unsupported(reason), .history: .unsupported(.unknownFormat),
                                                              .cookies: .unsupported(.unknownFormat), .passwords: .unsupported(.exportFromSource)])
            return BrowserSource(browser: browser, appURL: appURL, profiles: [profile])
        }
    }

    /// Opera's layout: the data folder itself is the profile; newer builds
    /// may also list `Default` / `Profile N` in `Local State`, so both count.
    static func rootProfileEntries(_ directory: URL, browser: ImportBrowser) -> [ChromiumProfileList.Entry] {
        let root = ChromiumProfileList.Entry(directoryName: "", displayName: browser.displayName)
        let listed = ChromiumProfileList().entries(in: directory).filter { !$0.directoryName.isEmpty }
        let rootHasData = ["Bookmarks", "Preferences", "History"].contains {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
        return rootHasData || listed.isEmpty ? [root] + listed : listed
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

    static func chromiumAvailability(_ profile: URL, browser: ImportBrowser) -> [ImportDataKind: DataAvailability] {
        let files = browser.source?.files
        func present(_ name: String?) -> Bool { name.map { FileManager.default.fileExists(atPath: profile.appending(path: $0).path) } ?? false }
        let sessions = profile.appending(path: "Sessions")
        let hasSession = ChromiumSessionReader().latestSessionFile(in: sessions) != nil || present("Current Session")
        return [
            .bookmarks: present(files?.bookmarks ?? "Bookmarks") ? .available : .absent,
            .history: present(files?.history ?? "History") ? .available : .absent,
            .openTabs: hasSession ? .available : .absent,
            .extensions: present("Extensions") ? .available : .absent,
            // Read only after the consent step (PasswordImporter).
            .passwords: !present(files?.passwords ?? "Login Data") ? .absent : browser.readsSavedPasswords ? .available : .unsupported(.exportFromSource),
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
            // Firefox keeps passwords in logins.json, sealed with the NSS key store key4.db.
            .passwords: session(firefoxPasswords(profile, present: present("logins.json"))),
            .cookies: session(present("cookies.sqlite") ? .available : .absent),
        ]
    }

    static func firefoxPasswords(_ profile: URL, present: Bool) -> DataAvailability {
        #if CMUX_NO_PASSWORD_IMPORT
        // The cx-f58x notary test build has no Firefox password reader.
        return present ? .unsupported(.exportFromSource) : .absent
        #else
        return FirefoxLoginReader.hasLogins(profile) ? .available : present ? .unsupported(.exportFromSource) : .absent
        #endif
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
