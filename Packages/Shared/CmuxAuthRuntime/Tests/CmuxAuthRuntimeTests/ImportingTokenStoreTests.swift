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

        #expect(await store.isShared(refreshToken: "refresh-n"))
        #expect(!(await store.isShared(refreshToken: "refresh-own")))
    }

    @Test func aPairWithoutARefreshTokenIsNoSession() {
        #expect(ImportedTokenPair(accessToken: "access", refreshToken: nil) == nil)
        #expect(ImportedTokenPair(accessToken: "access", refreshToken: "") == nil)
        #expect(ImportedTokenPair(accessToken: "", refreshToken: "refresh")?.accessToken == nil)
    }

    @Test func aKeychainReaderWithoutTheAccessGroupReadsNothing() {
        // The test bundle is not signed with this group: the data-protection Keychain refuses, quietly.
        let reader = KeychainTokenReader(service: "com.cmuxterm.app.nightly.auth.test-\(UUID().uuidString)",
                                         accessGroup: "7WLXT3NR37.com.cmuxterm.app.nightly")
        #expect(reader.read() == nil)
    }
}
