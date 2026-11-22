import CmuxNextBrowserImport
import Foundation
import Testing

/// Import from Browser finds every browser and browser-based app on the Mac,
/// with its profiles and a readable cookie store: one fixture home per source,
/// laid out like the real install (folder names, `Local State`, `profiles.ini`,
/// WebKit's `.binarycookies`). No real profile or Keychain item is touched.
struct EveryBrowserDetectionTests {
    /// A scratch home with empty files at `paths` (folders made on the way).
    final class Home {
        let url: URL

        init(_ paths: [String] = []) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "every-browser-\(UUID().uuidString)", directoryHint: .isDirectory)
            for path in paths { try write(path) }
        }

        func write(_ path: String, _ text: String = "x") throws {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        /// A Chromium user data folder: `Local State` and the profile folders, each with history and cookies.
        func chromium(_ folder: String, profiles: [String] = ["Default"]) throws {
            let cache = profiles.map { #""\#($0)":{"name":"\#($0 == "Default" ? "Personal" : $0)"}"# }.joined(separator: ",")
            try write("\(folder)/Local State", #"{"profile":{"info_cache":{\#(cache)}}}"#)
            for profile in profiles {
                let base = profile.isEmpty ? folder : "\(folder)/\(profile)"
                try write("\(base)/History")
                try write("\(base)/Network/Cookies")
            }
        }

        /// A Firefox-family folder with one profile in `profiles.ini`.
        func firefox(_ folder: String) throws {
            try write("\(folder)/profiles.ini", "[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abcd.default-release\nDefault=1\n")
            try write("\(folder)/Profiles/abcd.default-release/places.sqlite")
            try write("\(folder)/Profiles/abcd.default-release/cookies.sqlite")
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static func detect(_ home: Home) -> [BrowserSource] {
        BrowserSourceDetector(environment: ImportEnvironment(homeDirectory: home.url, locateApp: { _ in nil })).detect()
    }

    static let support = "Library/Application Support"

    /// Chromium browsers: data folder, the name the picker shows.
    static let chromiumBrowsers: [(folder: String, name: String)] = [
        ("Google/Chrome", "Google Chrome"),
        ("Google/Chrome Beta", "Google Chrome Beta"),
        ("Google/Chrome Canary", "Google Chrome Canary"),
        ("net.imput.helium", "Helium"),
        ("BraveSoftware/Brave-Browser", "Brave"),
        ("Arc/User Data", "Arc"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Dia/User Data", "Dia"),
        ("Comet", "Comet"),
        ("BrowserOS", "BrowserOS"),
        ("com.openai.atlas/browser-data/host", "ChatGPT Atlas"),
        // The ChatGPT app (com.openai.codex) keeps a Chromium profile in `Codex`.
        ("Codex", "ChatGPT"),
    ]

    @Test(arguments: chromiumBrowsers.map(\.folder))
    func chromiumBrowserIsFoundWithReadableCookies(folder: String) throws {
        let name = try #require(Self.chromiumBrowsers.first { $0.folder == folder }?.name)
        let home = try Home()
        try home.chromium("\(Self.support)/\(folder)")
        let source = try #require(Self.detect(home).first { $0.browser.displayName == name }, "\(name) is not listed")
        let profile = try #require(source.profiles.first)
        #expect(profile.availability(of: .cookies) == .available, "\(name) cookies: \(profile.availability(of: .cookies))")
        #expect(profile.availability(of: .history) == .available)
        #expect(source.browser.safeStorageService != nil)
    }

    @Test func everyChromeProfileIsListed() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/Google/Chrome", profiles: ["Default", "Profile 1", "Profile 2"])
        let chrome = try #require(Self.detect(home).first { $0.browser == .chrome })
        #expect(chrome.profiles.map(\.directoryName) == ["Default", "Profile 1", "Profile 2"])
        #expect(chrome.profiles.allSatisfy { $0.availability(of: .cookies) == .available })
    }

    @Test func operaKeepsItsProfileInTheDataFolder() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/com.operasoftware.Opera", profiles: [""])
        let opera = try #require(Self.detect(home).first { $0.browser == .opera })
        #expect(opera.profiles.first?.availability(of: .cookies) == .available)
    }

    @Test func theChatGPTAppUsesItsCodexKeychainItem() {
        // The ChatGPT app is com.openai.codex: its Keychain item is "Codex Safe Storage".
        #expect(ImportBrowser(rawValue: "chatGPT").safeStorageService == "Codex Safe Storage")
    }

    @Test(arguments: ["Firefox", "zen"])
    func firefoxFamilyBrowserIsFound(folder: String) throws {
        let home = try Home()
        try home.firefox("\(Self.support)/\(folder)")
        let source = try #require(Self.detect(home).first { $0.browser.dataDirectory.hasSuffix(folder) })
        #expect(source.profiles.first?.availability(of: .cookies) == .available)
    }

    @Test func safariIsFound() throws {
        let home = try Home(["Library/Safari/History.db",
                             "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"])
        let safari = try #require(Self.detect(home).first { $0.browser == .safari })
        #expect(safari.profiles.first?.availability(of: .cookies) == .available)
    }

    /// Orion is WebKit: its cookies are in WebKit's store for its bundle id.
    @Test func orionCookiesAreReadable() throws {
        let home = try Home(["\(Self.support)/Orion/Defaults/x", "Library/HTTPStorages/com.kagi.kagimacOS.binarycookies"])
        let orion = try #require(Self.detect(home).first { $0.browser == .orion })
        #expect(orion.profiles.first?.availability(of: .cookies) == .available)
        let query = try CookieSourceQuery("orion").resolve(in: Self.detect(home))
        #expect(query.browser == .orion)
    }

    /// The Claude desktop app is Electron: its data folder is the profile.
    @Test func claudeDesktopIsFound() throws {
        let home = try Home()
        try home.write("\(Self.support)/Claude/Local State", "{}")
        try home.write("\(Self.support)/Claude/Cookies")
        let sources = Self.detect(home)
        let claude = try #require(sources.first { $0.browser.displayName == "Claude" }, "Claude is not listed")
        #expect(claude.profiles.first?.availability(of: .cookies) == .available)
        #expect(claude.browser.safeStorageService == "Claude Safe Storage")
        #expect(try CookieSourceQuery("claude").resolve(in: sources).path.lastPathComponent == "Claude")
    }

    /// The first ChatGPT desktop app is native: URLSession's cookie store holds its session.
    @Test func chatGPTClassicCookiesAreReadable() throws {
        let home = try Home(["\(Self.support)/com.openai.chat/x", "Library/HTTPStorages/com.openai.chat.binarycookies"])
        let classic = try #require(Self.detect(home).first { $0.browser.bundleIDs.contains("com.openai.chat") }, "ChatGPT Classic is not listed")
        #expect(classic.profiles.first?.availability(of: .cookies) == .available)
    }

    /// A Chromium app no registry row names is found from its folder.
    @Test func unknownChromiumAppIsFoundFromItsFolder() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/Acme Notes")
        let acme = try #require(Self.detect(home).first { $0.browser.displayName == "Acme Notes" }, "Acme Notes is not listed")
        #expect(acme.profiles.first?.availability(of: .history) == .available)
        #expect(acme.browser.family == .chromium)
    }

    /// Records the Keychain items an import asks for; returns no key.
    final class RecordingKeys: SafeStorageKeyProviding, @unchecked Sendable {
        // Written once per test from the importer's one read; read after it returns.
        var asked: [SafeStorageName] = []
        func password(service: String) throws(CookieImportError) -> SecretBytes { try password(service: service, account: nil) }
        func password(service: String, account: String?) throws(CookieImportError) -> SecretBytes {
            asked.append(SafeStorageName(service: service, account: account))
            throw .keyNotFound(service: service)
        }
    }

    struct NoCookies: CookieDestination {
        func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
            CookieWriteResult(written: 0, rejected: cookies.count)
        }
    }

    static func detect(_ home: Home, keychain: [SafeStorageName]) -> [BrowserSource] {
        BrowserSourceDetector(environment: ImportEnvironment(homeDirectory: home.url, locateApp: { _ in nil },
                                                             safeStorageNames: { keychain })).detect()
    }

    /// An Electron app found from its folder uses the Keychain item named
    /// after it, and its Electron account when the service has two.
    @Test func foundAppUsesTheKeychainItemNamedAfterIt() async throws {
        let home = try Home()
        try home.write("\(Self.support)/Acme Notes/Local State", "{}")
        try home.write("\(Self.support)/Acme Notes/Cookies")
        let keychain = [SafeStorageName(service: "Acme Notes Safe Storage", account: "Acme Notes"),
                        SafeStorageName(service: "Acme Notes Safe Storage", account: "Acme Notes Key")]
        let acme = try #require(Self.detect(home, keychain: keychain).first { $0.browser.displayName == "Acme Notes" })
        let profile = try #require(acme.profiles.first)
        #expect(profile.availability(of: .cookies) == .available)
        #expect(acme.browser.safeStorageService == "Acme Notes Safe Storage")
        #expect(acme.browser.safeStorageAccount == "Acme Notes Key")

        let keys = RecordingKeys()
        _ = try? await CookieImporter(destination: NoCookies(), keys: keys).run(profile, into: "p")
        #expect(keys.asked == [SafeStorageName(service: "Acme Notes Safe Storage", account: "Acme Notes Key")])
    }

    /// Without a Keychain item, a found app's cookies show as encrypted, not as importable.
    @Test func foundAppWithoutKeychainItemKeepsCookiesLocked() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/Acme Notes")
        let acme = try #require(Self.detect(home, keychain: []).first { $0.browser.displayName == "Acme Notes" })
        #expect(acme.profiles.first?.availability(of: .cookies) == .unsupported(.sourceEncrypted))
    }

    /// A registry row whose item is not confirmed takes the one the Keychain lists.
    @Test func unconfirmedRowTakesTheListedItem() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/com.openai.atlas/browser-data/host")
        let atlas = try #require(Self.detect(home, keychain: [SafeStorageName(service: "ChatGPT Atlas Safe Storage", account: "ChatGPT Atlas")])
            .first { $0.browser.rawValue == "chatGPTAtlas" })
        #expect(atlas.browser.safeStorageService == "ChatGPT Atlas Safe Storage")
        #expect(atlas.profiles.first?.availability(of: .cookies) == .available)
    }

    /// The Claude app's cookie read asks for its Electron account.
    @Test func claudeCookiesAskForTheClaudeKeyAccount() async throws {
        let home = try Home()
        try home.write("\(Self.support)/Claude/Local State", "{}")
        try home.write("\(Self.support)/Claude/Cookies")
        let claude = try #require(Self.detect(home).first { $0.browser.displayName == "Claude" })
        let keys = RecordingKeys()
        _ = try? await CookieImporter(destination: NoCookies(), keys: keys).run(try #require(claude.profiles.first), into: "p")
        #expect(keys.asked == [SafeStorageName(service: "Claude Safe Storage", account: "Claude Key")])
    }

    /// A stored id of a found browser decodes to the same browser.
    @Test func foundBrowserIdentityIsItsRawValue() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/Acme Notes")
        let acme = try #require(Self.detect(home).first { $0.browser.displayName == "Acme Notes" }).browser
        let decoded = try JSONDecoder().decode(ImportBrowser.self, from: JSONEncoder().encode(acme))
        #expect(decoded == acme)
        #expect(acme.rawValue == "found.acme-notes")
        #expect(acme.isFoundOnDisk)
    }

    /// cmux's own browser data is never offered as a source.
    @Test func cmuxOwnFoldersAreNotSources() throws {
        let home = try Home()
        try home.chromium("\(Self.support)/cmux Nightly")
        try home.chromium("\(Self.support)/CEF")
        #expect(Self.detect(home).isEmpty)
    }
}
