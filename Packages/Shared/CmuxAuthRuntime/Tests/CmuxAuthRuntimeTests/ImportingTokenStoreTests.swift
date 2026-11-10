import Foundation
import Testing
@testable import CmuxAuthRuntime

@Suite struct ImportingTokenStoreTests {
    /// A source that counts its reads.
    private actor CountingSource {
        let pair: ImportedTokenPair?
        private(set) var reads = 0
        init(_ pair: ImportedTokenPair?) { self.pair = pair }
        func read() -> ImportedTokenPair? { reads += 1; return pair }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("importing-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func anEmptyStoreAdoptsTheFirstSourceWithASessionAndKeepsIt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = CountingSource(nil)
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let later = CountingSource(ImportedTokenPair(accessToken: "access-x", refreshToken: "refresh-x"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory),
                                        sources: [{ await empty.read() }, { await nightly.read() }, { await later.read() }])

        #expect(await store.getStoredRefreshToken() == "refresh-n")
        #expect(await store.getStoredAccessToken() == "access-n")
        #expect(await later.reads == 0)
        // Adopted into the primary store: a fresh store over the same file has it, with no source.
        let reopened = FileStackTokenStore(directory: directory)
        #expect(await reopened.getStoredRefreshToken() == "refresh-n")
        #expect(await nightly.reads == 1)
    }

    @Test func aSessionAdoptedFromThisAppsOwnEarlierStoreIsNotShared() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = CountingSource(ImportedTokenPair(accessToken: "access-e", refreshToken: "refresh-e"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory),
                                        sources: [{ await earlier.read() }], sharesSessions: false)

        #expect(await store.getStoredRefreshToken() == "refresh-e")
        // This app's own session: a sign-out revokes it on the server.
        #expect(await store.isShared(refreshToken: "refresh-e") == false)
    }

    @Test func aSignOutAlsoForgetsThisAppsOwnEarlierStore() async throws {
        let directory = try makeDirectory()
        let earlierDirectory = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: earlierDirectory)
        }
        let earlier = FileStackTokenStore(directory: earlierDirectory)
        await earlier.setTokens(accessToken: "access-e", refreshToken: "refresh-e")
        func launch() -> ImportingTokenStore {
            ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{
                ImportedTokenPair(accessToken: await earlier.getStoredAccessToken(), refreshToken: await earlier.getStoredRefreshToken())
            }], sharesSessions: false, forgetSources: { await earlier.clearTokens() })
        }

        let first = launch()
        #expect(await first.getStoredRefreshToken() == "refresh-e")
        await first.clearTokens()
        // The next launch finds the person signed out, not the session they signed out of.
        #expect(await launch().getStoredRefreshToken() == nil)
        #expect(await earlier.getStoredRefreshToken() == nil)
    }

    @Test func aStoreWithItsOwnSessionNeverReadsASource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = FileStackTokenStore(directory: directory)
        await own.setTokens(accessToken: "access-own", refreshToken: "refresh-own")
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: own, sources: [{ await nightly.read() }])

        #expect(await store.getStoredRefreshToken() == "refresh-own")
        #expect(await nightly.reads == 0)
    }

    @Test func signingOutClearsOnlyThePrimaryAndIsNotUndoneInTheProcess() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{ await nightly.read() }])

        #expect(await store.getStoredRefreshToken() == "refresh-n")
        await store.clearTokens()
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await store.getStoredAccessToken() == nil)
        #expect(await nightly.reads == 1)
    }

    @Test func aWriteBeforeTheFirstReadEndsTheImport() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{ await nightly.read() }])

        await store.setTokens(accessToken: "access-signin", refreshToken: "refresh-signin")
        #expect(await store.getStoredRefreshToken() == "refresh-signin")
        #expect(await nightly.reads == 0)
    }

    @Test func aRefreshAfterAnImportGoesToThePrimary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{ await nightly.read() }])

        await store.compareAndSet(compareRefreshToken: "refresh-n", newRefreshToken: "refresh-2", newAccessToken: "access-2")
        #expect(await store.getStoredRefreshToken() == "refresh-2")
        #expect(await store.getStoredAccessToken() == "access-2")
    }

    @Test func concurrentFirstReadsAllSeeTheAdoptedSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{ await nightly.read() }])

        let reads = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 { group.addTask { await store.getStoredRefreshToken() } }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(reads == Array(repeating: "refresh-n", count: 8))
        #expect(await nightly.reads == 1)
    }

    @Test func aSignInRacingTheImportIsNotOverwritten() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{ await nightly.read() }])

        async let read = store.getStoredRefreshToken()
        async let signIn: Void = store.setTokens(accessToken: "access-signin", refreshToken: "refresh-signin")
        _ = await (read, signIn)
        // Whichever ran first, the sign-in's pair is the one left stored.
        #expect(await store.getStoredRefreshToken() == "refresh-signin")
    }

    @Test func onlyTheSourcesCurrentSessionIsShared() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nightly = CountingSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: FileStackTokenStore(directory: directory), sources: [{ await nightly.read() }])

        // Nothing adopted yet: nothing is shared, and the question reads no source.
        #expect(!(await store.isShared(refreshToken: "refresh-n")))
        #expect(await nightly.reads == 0)
        #expect(await store.getStoredRefreshToken() == "refresh-n")
        #expect(await store.isShared(refreshToken: "refresh-n"))
        #expect(!(await store.isShared(refreshToken: "refresh-own")))
        #expect(await nightly.reads == 1)
    }

    @Test func aPairWithoutARefreshTokenIsNoSession() {
        #expect(ImportedTokenPair(accessToken: "access", refreshToken: nil) == nil)
        #expect(ImportedTokenPair(accessToken: "access", refreshToken: "") == nil)
        #expect(ImportedTokenPair(accessToken: "", refreshToken: "refresh")?.accessToken == nil)
    }

    /// A source whose session can go away (NIGHTLY quit or signed out).
    private actor SwitchableSource {
        var pair: ImportedTokenPair?
        init(_ pair: ImportedTokenPair?) { self.pair = pair }
        func read() -> ImportedTokenPair? { pair }
        func set(_ pair: ImportedTokenPair?) { self.pair = pair }
    }

    @Test func anAdoptedSessionStaysSharedAfterSignOutAndAfterTheSourceIsGone() async {
        let nightly = SwitchableSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: MemoryStackTokenStore(), sources: [{ await nightly.read() }])

        #expect(await store.getStoredRefreshToken() == "refresh-n")
        // The sign-out clears the store first, and NIGHTLY may have quit by the time revocation asks.
        await store.clearTokens()
        await nightly.set(nil)
        #expect(await store.isShared(refreshToken: "refresh-n"))
        #expect(!(await store.isShared(refreshToken: "refresh-other")))
    }

    @Test func aRefreshOfAnAdoptedSessionIsStillShared() async {
        let nightly = SwitchableSource(ImportedTokenPair(accessToken: "access-n", refreshToken: "refresh-n"))
        let store = ImportingTokenStore(primary: MemoryStackTokenStore(), sources: [{ await nightly.read() }])

        #expect(await store.getStoredRefreshToken() == "refresh-n")
        await store.compareAndSet(compareRefreshToken: "refresh-n", newRefreshToken: "refresh-n2", newAccessToken: "access-n2")
        await nightly.set(nil)
        #expect(await store.isShared(refreshToken: "refresh-n2"))
        // A session this app signed in by itself is its own: a sign-out revokes it.
        await store.setTokens(accessToken: "access-own", refreshToken: "refresh-own")
        #expect(!(await store.isShared(refreshToken: "refresh-own")))
    }

    @Test func theMemoryStoreKeepsThePairInTheProcessOnly() async {
        let store = MemoryStackTokenStore()
        await store.setTokens(accessToken: "access", refreshToken: "refresh")
        #expect(await store.getStoredRefreshToken() == "refresh")
        await store.compareAndSet(compareRefreshToken: "stale", newRefreshToken: "x", newAccessToken: "y")
        #expect(await store.getStoredAccessToken() == "access")
        await store.compareAndSet(compareRefreshToken: "refresh", newRefreshToken: "refresh-2", newAccessToken: "access-2")
        #expect(await store.getStoredRefreshToken() == "refresh-2")
        #expect(await MemoryStackTokenStore().getStoredRefreshToken() == nil)
        await store.clearTokens()
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await store.getStoredAccessToken() == nil)
    }

    #if DEBUG && os(macOS)
    @Test func anAdoptedTokenNeverReachesTheAuthLogFile() async throws {
        let refresh = "handoff-refresh-\(UUID().uuidString)"
        let access = "handoff-access-\(UUID().uuidString)"
        let store = ImportingTokenStore(primary: MemoryStackTokenStore(),
                                        sources: [{ ImportedTokenPair(accessToken: access, refreshToken: refresh) }])
        #expect(await store.getStoredRefreshToken() == refresh)
        await store.clearTokens()
        // AuthDebugLog's file sink in DEBUG macOS builds: the adoption wrote its line there.
        let path = "/tmp/cmux-auth-debug.log"
        let log = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // Another user's file there takes no lines (AuthDebugLog refuses it); then only absence is checked.
        if FileManager.default.isWritableFile(atPath: path) { #expect(log.contains("importing.store: adopted a session")) }
        #expect(!log.contains(refresh))
        #expect(!log.contains(access))
    }
    #endif
}
