import CMUXAuthCore
import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

/// A dev build takes the running NIGHTLY's session only when the dev sign-in inputs name no account, and then only
/// reads it: NIGHTLY's own store never changes (``CloudAuth/adoptsNightlySession(configuration:devAccount:)``).
@MainActor @Suite struct CloudAuthNightlyAdoptionTests {
    /// NIGHTLY's stored session, as the handoff hands it out; counts every read.
    actor Nightly {
        var refresh: String?
        var access: String?
        var reads = 0
        var pair: [String?] { [refresh, access] }
        init(refresh: String?, access: String? = nil) { (self.refresh, self.access) = (refresh, access) }
        /// The person signs NIGHTLY in.
        func signIn(refresh: String, access: String) { (self.refresh, self.access) = (refresh, access) }
        func handOff() -> (accessToken: String?, refreshToken: String)? {
            reads += 1
            return refresh.map { (access, $0) }
        }
    }

    /// A tagged dev build (`dev:next`) on `production` auth.
    static func devBuild(production: Bool = true) -> CloudConfiguration {
        var configuration = CloudConfiguration.unavailable
        configuration.isProductionAuth = production
        configuration.buildSpace = CMUXBuildSpaceState(devBuild: true, devTag: "next")
        return configuration
    }

    /// A temporary home with `files` (path relative to it, contents).
    static func home(_ files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nightly-adoption-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    @Test func aConfiguredAccountIsUsedAndNightlyIsNeverRead() async throws {
        let accounts: [(files: [String: String], environment: [String: String])] = [
            ([".config/cmux/dev-account": "personal\n"], [:]),
            ([".secrets/cmuxterm-dev.env": "CMUX_DOGFOOD_STACK_EMAIL=person@example.com\nCMUX_DOGFOOD_STACK_PASSWORD=x\n"], [:]),
            ([".secrets/cmuxterm-dev.env": "export CMUX_UITEST_STACK_EMAIL=\"agent@example.com\"\n"], [:]),
            ([:], ["CMUX_DEV_AUTH_ACCOUNT": "agent"]),
            ([:], ["CMUX_UITEST_STACK_EMAIL": "agent@example.com"]),
        ]
        for account in accounts {
            let home = try Self.home(account.files)
            #expect(CloudAuth.devAccountConfigured(environment: account.environment, home: home))
            let nightly = Nightly(refresh: "refresh-n")
            let store = CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: { await nightly.handOff() },
                                             devAccount: true)
            #expect(!CloudAuth.adoptsNightlySession(configuration: Self.devBuild(), devAccount: true))
            #expect(!(store is ImportingTokenStore))
            #expect(await nightly.reads == 0)
        }
    }

    @Test func noConfiguredAccountAdoptsNightlysSessionReadOnly() async throws {
        let home = try Self.home([".secrets/cmuxterm-dev.env": "CMUX_DOGFOOD_STACK_EMAIL=\nOTHER=1\n"])
        #expect(!CloudAuth.devAccountConfigured(environment: [:], home: home))
        let nightly = Nightly(refresh: "refresh-n", access: "access-n")
        let store = try #require(CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: { await nightly.handOff() },
                                                      devAccount: false) as? ImportingTokenStore)
        #expect(await store.getStoredRefreshToken() == "refresh-n")
        #expect(await store.getStoredAccessToken() == "access-n")
        #expect(await store.isShared(refreshToken: "refresh-n"))
        #expect(await nightly.reads == 1)
    }

    @Test func nightlySignedOutLeavesTheDevBuildSignedOut() async throws {
        let nightly = Nightly(refresh: nil)
        let store = CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: { await nightly.handOff() },
                                         devAccount: false)
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await store.getStoredAccessToken() == nil)
        // No NIGHTLY to ask at all is signed out too.
        let alone = CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: nil, devAccount: false)
        #expect(await alone.getStoredRefreshToken() == nil)
    }

    @Test func aRefreshOrSignOutInTheDevBuildNeverWritesNightlysStore() async throws {
        let nightly = Nightly(refresh: "refresh-n", access: "access-n")
        let store = try #require(CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: { await nightly.handOff() },
                                                      devAccount: false) as? ImportingTokenStore)
        #expect(await store.getStoredRefreshToken() == "refresh-n")
        // A refresh rotates the pair (StackAuthClient's compare-and-set): only the dev build's memory store changes.
        await store.compareAndSet(compareRefreshToken: "refresh-n", newRefreshToken: "refresh-2", newAccessToken: "access-2")
        #expect(await store.getStoredRefreshToken() == "refresh-2")
        #expect(await nightly.pair == ["refresh-n", "access-n"])
        // The refreshed session is still NIGHTLY's: a sign-out here keeps it alive on the server.
        #expect(await store.isShared(refreshToken: "refresh-2"))
        await store.clearTokens()
        #expect(await nightly.pair == ["refresh-n", "access-n"])
        #expect(await nightly.reads == 1)
    }

    @Test func onlyATaggedDevBuildOnTheProductionAccountAdopts() {
        #expect(CloudAuth.adoptsNightlySession(configuration: Self.devBuild(), devAccount: false))
        // A staging dev build: NIGHTLY's production session is not its account's.
        #expect(!CloudAuth.adoptsNightlySession(configuration: Self.devBuild(production: false), devAccount: false))
        var nightly = CloudConfiguration.unavailable
        nightly.isProductionAuth = true
        #expect(!CloudAuth.adoptsNightlySession(configuration: nightly, devAccount: false))
    }

    /// NIGHTLY, RC and release (no build space), and a dev build with no usable tag, never open the dev sign-in files.
    @Test func onlyABuildThatWouldAdoptReadsTheDevSignInFiles() throws {
        let home = try Self.home([".config/cmux/dev-account": "personal\n"])
        var nightly = CloudConfiguration.unavailable
        nightly.isProductionAuth = true
        var misconfigured = Self.devBuild()
        misconfigured.buildSpace = CMUXBuildSpaceState(devBuild: true, devTag: nil)
        for configuration in [nightly, misconfigured, Self.devBuild(production: false)] {
            var reads: [String] = []
            let devAccount = CloudAuth.launchDevAccount(configuration: configuration, environment: [:], home: home) { path in
                reads.append(path)
                return CloudAuth.readDevSignInFile(path)
            }
            #expect(reads.isEmpty, "\(configuration.buildSpace) read \(reads)")
            // Its own store either way: the answer never makes it adopt.
            #expect(devAccount)
            #expect(!CloudAuth.adoptsNightlySession(configuration: configuration, devAccount: devAccount))
        }
        // A tagged dev build on the production account reads them, and the file wins.
        var reads = 0
        #expect(CloudAuth.launchDevAccount(configuration: Self.devBuild(), environment: [:], home: home) { path in
            reads += 1
            return CloudAuth.readDevSignInFile(path)
        })
        #expect(reads == 1)
    }

    /// A dev-account or secrets file that is there but cannot be read counts as configured: fail closed.
    @Test func anUnreadableDevSignInFileCountsAsAnAccount() throws {
        // A directory where the file goes cannot be read as text, whoever runs the test.
        for path in [".config/cmux/dev-account", ".secrets/cmuxterm-dev.env"] {
            let home = try Self.home([:])
            try FileManager.default.createDirectory(atPath: home + "/" + path, withIntermediateDirectories: true)
            #expect(CloudAuth.readDevSignInFile(home + "/" + path) == .unreadable)
            #expect(CloudAuth.devAccountConfigured(environment: [:], home: home), "\(path)")
            #expect(CloudAuth.launchDevAccount(configuration: Self.devBuild(), environment: [:], home: home))
        }
        // An owner-unreadable file (root reads it anyway).
        if getuid() != 0 {
            let home = try Self.home([".secrets/cmuxterm-dev.env": "CMUX_DOGFOOD_STACK_EMAIL=person@example.com\n"])
            let secrets = home + "/.secrets/cmuxterm-dev.env"
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secrets)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secrets) }
            #expect(CloudAuth.readDevSignInFile(secrets) == .unreadable)
            #expect(CloudAuth.devAccountConfigured(environment: [:], home: home))
        }
        // Invalid UTF-8 is unreadable too.
        let home = try Self.home([:])
        try FileManager.default.createDirectory(atPath: home + "/.config/cmux", withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0xFD]).write(to: URL(fileURLWithPath: home + "/.config/cmux/dev-account"))
        #expect(CloudAuth.devAccountConfigured(environment: [:], home: home))
        // Nothing there is not an account; nor is a missing parent folder.
        #expect(CloudAuth.readDevSignInFile(try Self.home([:]) + "/.config/cmux/dev-account") == .missing)
        #expect(!CloudAuth.devAccountConfigured(environment: [:], home: try Self.home([:])))
    }

    /// A dev build started before NIGHTLY signed in adopts its session when the person asks (opens sign-in or Cloud),
    /// without a relaunch; nothing polls in between.
    @Test func aDevBuildStartedBeforeNightlyAdoptsWhenAskedAgain() async throws {
        let nightly = Nightly(refresh: nil)
        let store = try #require(CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: { await nightly.handOff() },
                                                      devAccount: false) as? ImportingTokenStore)
        #expect(await store.getStoredRefreshToken() == nil)
        await nightly.signIn(refresh: "refresh-n", access: "access-n")
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await nightly.reads == 1)
        #expect(await store.retryImport())
        #expect(await store.getStoredRefreshToken() == "refresh-n")
        #expect(await store.getStoredAccessToken() == "access-n")
        // Still NIGHTLY's: a sign-out here leaves it alive on the server.
        #expect(await store.isShared(refreshToken: "refresh-n"))
        #expect(await nightly.reads == 2)
        // Signed in now: asking again reads nothing.
        #expect(!(await store.retryImport()))
        #expect(await nightly.reads == 2)
        #expect(CloudAuth.nightlyAdoption(of: store, configuration: Self.devBuild(), devAccount: false, memoryOnly: false) === store)
    }

    /// A sign-in or sign-out in the dev build ends adopting for the process: asking again never brings NIGHTLY's back.
    @Test func aSignOutInTheDevBuildIsNeverUndoneByAskingAgain() async throws {
        let nightly = Nightly(refresh: "refresh-n", access: "access-n")
        let store = try #require(CloudAuth.tokenStore(configuration: Self.devBuild(), nightlySession: { await nightly.handOff() },
                                                      devAccount: false) as? ImportingTokenStore)
        #expect(await store.getStoredRefreshToken() == "refresh-n")
        await store.clearTokens()
        #expect(!(await store.retryImport()))
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await nightly.reads == 1)
        // Only the NIGHTLY-adopting store is asked again: not a configured account's, not a memory-only launch's.
        #expect(CloudAuth.nightlyAdoption(of: store, configuration: Self.devBuild(), devAccount: true, memoryOnly: false) == nil)
        #expect(CloudAuth.nightlyAdoption(of: store, configuration: Self.devBuild(), devAccount: false, memoryOnly: true) == nil)
    }
}
