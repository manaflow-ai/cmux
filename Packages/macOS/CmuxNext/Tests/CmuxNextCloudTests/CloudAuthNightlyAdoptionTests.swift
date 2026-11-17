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
        // A refresh rotates the pair: only the dev build's memory store changes.
        await store.setTokens(accessToken: "access-2", refreshToken: "refresh-2")
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
}
