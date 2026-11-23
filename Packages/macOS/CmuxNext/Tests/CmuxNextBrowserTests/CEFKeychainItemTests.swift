import Foundation
import Security
import Testing
@testable import CmuxNextBrowser

/// "cmux NIGHTLY wants to use your confidential information stored in "Chromium Safe Storage" in your keychain"
/// (m1max, 2026-11-17, after an update). Embedded Chromium kept its cookie key in the "Chromium Safe Storage" item
/// every Chromium build shares; on that Mac ungoogled-chromium made it in 2021, so it trusted only that app and macOS
/// asked cmux on every launch. cmux never prompts for a keychain item unless the person imports from another browser.
@Suite struct CEFKeychainItemTests {
    // MARK: The item

    @Test(arguments: ["com.cmuxterm.app.nightly", "com.cmuxterm.app.next", "com.cmuxterm.app.rc"])
    func eachChannelHasItsOwnItemThatIsNeverTheSharedOne(bundle: String) {
        let item = CEFKeychainItem.forApplication(bundleIdentifier: bundle)
        #expect(item == CEFKeychainItem(service: "cmux Safe Storage", account: bundle))
        #expect(!CEFKeychainItem.isShared(service: item.service, account: item.account))
    }

    /// The item is named by the bundle only, never the version or the build: an update reads the same item, and a
    /// Developer ID update keeps the designated requirement the item trusts, so it reads it without asking.
    @Test func theItemOutlivesUpdates() {
        #expect(CEFKeychainItem.forApplication(bundleIdentifier: "com.cmuxterm.app.nightly")
            == CEFKeychainItem.forApplication(bundleIdentifier: "com.cmuxterm.app.nightly"))
        #expect(CEFKeychainItem.forApplication(bundleIdentifier: nil).account == "com.cmuxterm.app.next")
    }

    @Test(arguments: [("Chromium Safe Storage", "x"), ("chrome safe storage", "x"), ("x", "Chromium"), ("x", "CHROME")])
    func theSharedNamesAreRecognized(service: String, account: String) {
        #expect(CEFKeychainItem.isShared(service: service, account: account))
    }

    // MARK: Chromium's switches

    /// A shim stand-in for `cmux_shim_set_keychain_item` that records what it was given.
    private nonisolated(unsafe) static var given: [(String, String)] = []
    private static let accept: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { service, account in
        given.append((String(cString: service!), String(cString: account!)))
        return 1
    }
    private static let refuse: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _ in 0 }

    @Test(.serialized, arguments: [true, false])
    func aReleaseBuildUsesTheRealKeychainOnlyWithItsOwnItem(forkTakesIt: Bool) {
        Self.given = []
        let item = CEFKeychainItem.forApplication(bundleIdentifier: "com.cmuxterm.app.nightly")
        var switches = CEFSwitches.current(forkAPIVersion: 52, bundleIdentifier: item.account, environment: [:])
        #expect(!switches.useMockKeychain)
        let taken = CEFRuntime.applyKeychainItem(item, to: &switches, set: forkTakesIt ? Self.accept : Self.refuse)
        #expect(taken == forkTakesIt)
        // Refused: Chromium never reaches the real keychain, where it would read the shared item.
        #expect(switches.useMockKeychain == !forkTakesIt)
        #expect(switches.arguments.contains("use-mock-keychain") == !forkTakesIt)
        if forkTakesIt { #expect(Self.given.map { [$0.0, $0.1] } == [["cmux Safe Storage", "com.cmuxterm.app.nightly"]]) }
    }

    @Test func aShimWithoutTheCallKeepsChromiumOffTheRealKeychain() {
        var switches = CEFSwitches.current(forkAPIVersion: 24, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        let item = CEFKeychainItem.forApplication(bundleIdentifier: "com.cmuxterm.app.next")
        #expect(!CEFRuntime.applyKeychainItem(item, to: &switches, set: nil))
        #expect(switches.arguments.contains("use-mock-keychain"))
    }

    @Test func aDevelopmentBuildStaysOnTheMockKeychainAndSetsNoItem() {
        Self.given = []
        var switches = CEFSwitches.current(forkAPIVersion: 52, bundleIdentifier: "com.cmuxterm.app.debug.tag", environment: [:])
        let item = CEFKeychainItem.forApplication(bundleIdentifier: "com.cmuxterm.app.debug.tag")
        #expect(!CEFRuntime.applyKeychainItem(item, to: &switches, set: Self.accept))
        #expect(switches.arguments.contains("use-mock-keychain"))
        #expect(Self.given.isEmpty)
    }

    /// The Chromium host app sets no item of its own, so it never runs on the real keychain, in any channel.
    @Test(arguments: ["com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func theChromiumHostNeverUsesTheRealKeychain(bundle: String) {
        let app = URL(filePath: "/Applications/cmux NIGHTLY.app")
        let frameworks = app.appending(path: "Contents/Frameworks")
        let layout = CEFRuntimeLayout(frameworksDirectory: frameworks, mainBundle: app,
                                      helperApp: frameworks.appending(path: "cmux NIGHTLY Helper.app"))
        let arguments = ChromiumHostConfiguration.arguments(layout: layout, rootCache: URL(filePath: "/tmp/host"),
                                                            bundleIdentifier: bundle, environment: [:])
        #expect(arguments.contains("--cef-switch=use-mock-keychain"))
    }

    // MARK: The one-time move to the own item

    private final class FakeKeychain: CEFKeychainAccess, @unchecked Sendable {
        var items: [String: Data] = [:]
        /// Items this app may read without a prompt (it made them, or Always Allow).
        var trusted: Set<String> = []
        var reads: [String] = []
        var adds: [String] = []
        var addStatus: OSStatus = errSecSuccess
        /// No default keychain (a fresh `HOME`).
        var missing = false
        var missingChecks = 0

        static func key(_ service: String, _ account: String) -> String { service + "/" + account }
        func defaultKeychainMissing() -> Bool { missingChecks += 1; return missing }
        func exists(service: String, account: String) -> Bool { items[Self.key(service, account)] != nil }
        func readWithoutUI(service: String, account: String) -> Data? {
            let key = Self.key(service, account)
            reads.append(key)
            return trusted.contains(key) ? items[key] : nil
        }
        func add(service: String, account: String, secret: Data) -> OSStatus {
            adds.append(Self.key(service, account))
            if addStatus == errSecSuccess { items[Self.key(service, account)] = secret }
            return addStatus
        }
    }

    private static let shared = FakeKeychain.key("Chromium Safe Storage", "Chromium")
    private static let item = CEFKeychainItem.forApplication(bundleIdentifier: "com.cmuxterm.app.nightly")
    private static let own = FakeKeychain.key(item.service, item.account)

    private func profile(_ hasLocalState: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if hasLocalState { try Data("{}".utf8).write(to: root.appending(path: "Local State")) }
        return root
    }

    @Test func anExistingOwnItemIsAllThatIsLookedAt() throws {
        let keychain = FakeKeychain()
        keychain.items = [Self.own: Data("own".utf8), Self.shared: Data("shared".utf8)]
        keychain.trusted = [Self.shared]
        #expect(CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(true), keychain: keychain) == .ownItemExists)
        #expect(keychain.reads.isEmpty && keychain.adds.isEmpty)
    }

    @Test func aFreshProfileNeverTouchesTheSharedItem() throws {
        let keychain = FakeKeychain()
        keychain.items = [Self.shared: Data("shared".utf8)]
        keychain.trusted = [Self.shared]
        #expect(CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(false), keychain: keychain) == .freshProfile)
        #expect(keychain.reads.isEmpty && keychain.adds.isEmpty)
    }

    /// cmux made the shared item (or the person chose Always Allow): the own item gets the same key, so cookies and
    /// saved passwords stay readable.
    @Test func aSharedItemThisAppMayReadSilentlyMovesItsKey() throws {
        let keychain = FakeKeychain()
        keychain.items = [Self.shared: Data("shared-key".utf8)]
        keychain.trusted = [Self.shared]
        #expect(CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(true), keychain: keychain) == .copiedSharedKey)
        #expect(keychain.items[Self.own] == Data("shared-key".utf8))
    }

    /// Another app's shared item (the m1max case): nothing asks and nothing is copied; Chromium makes a new key.
    @Test func anotherAppsSharedItemIsNeverAskedFor() throws {
        let keychain = FakeKeychain()
        keychain.items = [Self.shared: Data("ungoogled".utf8)]
        #expect(CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(true), keychain: keychain) == .sharedKeyNotReadable)
        #expect(keychain.reads == [Self.shared])
        #expect(keychain.adds.isEmpty)
    }

    /// cmux19, 2026-11-21 06:44Z: a throwaway NIGHTLY copy in a fresh `HOME` with no login keychain logged
    /// "keychain item: freshProfile", then Chromium's `SecItemAdd` raised "Keychain Not Found" (Cancel, Help, Reset To
    /// Defaults) that nobody answered. With no keychain nothing is looked up or added, and Chromium runs on the mock one.
    @Test(arguments: [true, false])
    func noKeychainMeansNoKeychainCallAndTheMockKeychain(hasProfile: Bool) throws {
        let keychain = FakeKeychain()
        keychain.missing = true
        keychain.items = [Self.shared: Data("shared".utf8)]
        keychain.trusted = [Self.shared]
        let outcome = CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(hasProfile), keychain: keychain)
        #expect(outcome == .noKeychain)
        #expect(keychain.reads.isEmpty && keychain.adds.isEmpty)
        var switches = CEFSwitches.current(forkAPIVersion: 52, bundleIdentifier: Self.item.account, environment: [:])
        #expect(CEFRuntime.applyNoKeychain(outcome, to: &switches))
        #expect(switches.arguments.contains("use-mock-keychain"))
        // The fork is then given no item: Chromium never reaches the real keychain.
        Self.given = []
        #expect(!CEFRuntime.applyKeychainItem(Self.item, to: &switches, set: Self.accept))
        #expect(Self.given.isEmpty)
    }

    /// A keychain that exists keeps the real path: only the missing keychain turns to the mock one.
    @Test(arguments: [CEFKeychainMigration.Outcome.freshProfile, .ownItemExists, .copiedSharedKey, .sharedKeyNotReadable, nil])
    func everyOtherOutcomeKeepsTheRealKeychain(outcome: CEFKeychainMigration.Outcome?) {
        var switches = CEFSwitches.current(forkAPIVersion: 52, bundleIdentifier: Self.item.account, environment: [:])
        #expect(!CEFRuntime.applyNoKeychain(outcome, to: &switches))
        #expect(!switches.useMockKeychain)
    }

    @Test func anotherProcessThatMadeTheItemFirstWins() throws {
        let keychain = FakeKeychain()
        keychain.items = [Self.shared: Data("shared-key".utf8)]
        keychain.trusted = [Self.shared]
        keychain.addStatus = errSecDuplicateItem
        #expect(CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(true), keychain: keychain) == .copiedSharedKey)
        keychain.addStatus = errSecIO
        #expect(CEFKeychainMigration.prepare(item: Self.item, profileRoot: try profile(true), keychain: keychain) == .addFailed(errSecIO))
    }

    // MARK: Guards over the sources

    private static let sources = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private static func swiftFiles() throws -> [(path: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
            (String(url.path.dropFirst(sources.path.count + 1)), try String(contentsOf: url, encoding: .utf8))
        }
    }

    /// Chromium starts only after it was given cmux's own item (or the mock keychain).
    @Test func chromiumIsGivenItsOwnItemBeforeItStarts() throws {
        let runtime = try String(contentsOf: Self.sources.appending(path: "CmuxNextBrowser/CEF/CEFRuntime.swift"), encoding: .utf8)
        let apply = try #require(runtime.range(of: "Self.applyKeychainItem(keychainItem, to: &switchSet"))
        let switches = try #require(runtime.range(of: "let switches = switchSet.arguments"))
        let initialize = try #require(runtime.range(of: "shim.initialize("))
        #expect(apply.lowerBound < switches.lowerBound && switches.lowerBound < initialize.lowerBound)
    }

    /// Only the browser import reads another browser's Safe Storage item, where macOS's question is the person's
    /// consent. A keychain read that names a Safe Storage item anywhere else must not exist.
    @Test func onlyTheImportReadsSafeStorageItems() throws {
        let allowed = ["CmuxNextBrowserImport/", "CmuxNextBrowser/CEF/CEFKeychainItem.swift", "CmuxNextCompat/LoginKeychain.swift"]
        let readers = try Self.swiftFiles().filter { file in
            (file.text.contains("SecItemCopyMatching") || file.text.contains("SecKeychainFindGenericPassword")
                || file.text.contains("kSecReturnData")) && file.text.contains("Safe Storage")
        }.map(\.path)
        #expect(readers.filter { path in !allowed.contains { path.hasPrefix($0) } } == [])
    }

    /// The prompting key reader (`SafeStorageKeys().live()`) runs only from an import the person started or the
    /// cookie sync they turned on after one. A new caller is a new place macOS may ask: review it for consent first.
    @Test func thePromptingKeyReaderHasOnlyImportCallers() throws {
        let callers = try Self.swiftFiles().filter { $0.text.contains("SafeStorageKeys().live()") }.map(\.path).sorted()
        #expect(callers == [
            "CmuxNextApp/Onboarding/AppOnboardingServices.swift",
            "CmuxNextCookieImport/CookieImportService.swift",
            "CmuxNextImportCards/ImportSuggestionsCenter+Jobs.swift",
            "CmuxNextOnboarding/System/BrowserFolderAccess.swift",
        ])
    }
}
