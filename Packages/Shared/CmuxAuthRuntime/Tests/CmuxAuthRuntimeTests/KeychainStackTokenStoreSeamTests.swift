import CmuxSafeConcurrency
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// An in-memory Keychain with the matching rule the store relies on: service and account must match, and
/// a query without an access group matches an item in any group.
final class InMemoryKeychain: KeychainItemStoring {
    struct Item: Equatable, Sendable {
        var data: Data
        var deviceOnly: Bool
        var usesDataProtectionKeychain: Bool
    }

    struct Key: Hashable, Sendable {
        let service: String
        let account: String
        let accessGroup: String?
    }

    private let state = Mutex<[Key: Item]>([:])
    private let refusesAdds: Bool

    init(refusesAdds: Bool = false) {
        self.refusesAdds = refusesAdds
    }

    /// Puts an item in place as an older build left it: not yet device-only.
    func seed(_ key: Key, _ value: String, usesDataProtectionKeychain: Bool) {
        state.withLock {
            $0[key] = Item(
                data: Data(value.utf8),
                deviceOnly: false,
                usesDataProtectionKeychain: usesDataProtectionKeychain
            )
        }
    }

    func item(_ key: Key) -> Item? {
        state.withLock { $0[key] }
    }

    var keys: Set<Key> {
        state.withLock { Set($0.keys) }
    }

    func copyData(_ item: KeychainItemAddress) -> (status: KeychainItemStatus, data: Data?) {
        state.withLock { items in
            guard let key = Self.match(item, in: items) else { return (.itemNotFound, nil) }
            return (.success, items[key]?.data)
        }
    }

    func update(_ item: KeychainItemAddress, data: Data?) -> KeychainItemStatus {
        state.withLock { items in
            guard let key = Self.match(item, in: items) else { return .itemNotFound }
            items[key]?.deviceOnly = true
            if let data { items[key]?.data = data }
            return .success
        }
    }

    func add(_ item: KeychainItemAddress, data: Data) -> KeychainItemStatus {
        guard !refusesAdds else { return .failed(-34018) }
        return state.withLock { items in
            items[Key(service: item.service, account: item.account, accessGroup: item.accessGroup)] = Item(
                data: data,
                deviceOnly: true,
                usesDataProtectionKeychain: item.usesDataProtectionKeychain
            )
            return .success
        }
    }

    func delete(_ item: KeychainItemAddress) -> KeychainItemStatus {
        state.withLock { items in
            let matching = items.keys.filter { Self.matches(item, $0) }
            guard !matching.isEmpty else { return .itemNotFound }
            for key in matching { items[key] = nil }
            return .success
        }
    }

    private static func match(_ item: KeychainItemAddress, in items: [Key: Item]) -> Key? {
        items.keys.sorted { "\($0)" < "\($1)" }.first { matches(item, $0) }
    }

    private static func matches(_ item: KeychainItemAddress, _ key: Key) -> Bool {
        key.service == item.service
            && key.account == item.account
            && (item.accessGroup == nil || item.accessGroup == key.accessGroup)
    }
}

/// The store's adoption, hardening and clear rules over the Keychain seam; these run on every platform.
struct KeychainStackTokenStoreSeamTests {
    private static let service = "dev.cmux.test.auth"
    private static let group = "TEAMID.dev.cmux.test"
    private static let project = "project-1"

    private static func current(_ account: String, group: String? = group) -> InMemoryKeychain.Key {
        .init(service: service, account: account, accessGroup: group)
    }

    private static func legacy(_ account: String, group: String? = group) -> InMemoryKeychain.Key {
        .init(service: "", account: account, accessGroup: group)
    }

    @Test func tokensAreWrittenAsDeviceOnlyDataProtectionItemsAndReadBack() async {
        let keychain = InMemoryKeychain()
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: nil,
            keychain: keychain
        )

        #expect(await store.trySetTokens(accessToken: "access", refreshToken: "refresh"))

        let access = keychain.item(Self.current("cmux-auth-access-token"))
        #expect(access?.data == Data("access".utf8))
        #expect(access?.deviceOnly == true)
        #expect(access?.usesDataProtectionKeychain == true)
        let reread = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: nil,
            keychain: keychain
        )
        #expect(await reread.getStoredRefreshToken() == "refresh")
    }

    @Test func readingAnOlderItemHardensItToDeviceOnly() async {
        let keychain = InMemoryKeychain()
        keychain.seed(Self.current("cmux-auth-refresh-token"), "refresh", usesDataProtectionKeychain: true)
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: nil,
            keychain: keychain
        )

        #expect(await store.getStoredRefreshToken() == "refresh")
        #expect(keychain.item(Self.current("cmux-auth-refresh-token"))?.deviceOnly == true)
    }

    @Test func aLegacyStackItemIsAdoptedIntoTheCurrentAccountUnderTheSignedGroup() async {
        let keychain = InMemoryKeychain()
        let legacyAccount = "stack-auth-refresh-\(Self.project)"
        keychain.seed(Self.legacy(legacyAccount), "legacy-refresh", usesDataProtectionKeychain: false)
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: Self.project,
            keychain: keychain
        )

        #expect(await store.getStoredRefreshToken() == "legacy-refresh")
        #expect(keychain.item(Self.current("cmux-auth-refresh-token"))?.data == Data("legacy-refresh".utf8))
        #expect(keychain.item(Self.legacy(legacyAccount)) == nil)
    }

    @Test func withoutTheSignedGroupALegacyItemIsNeverAdopted() async {
        let keychain = InMemoryKeychain()
        let legacyKey = Self.legacy("stack-auth-refresh-\(Self.project)", group: "TEAMID.another.bundle")
        keychain.seed(legacyKey, "other-bundle-refresh", usesDataProtectionKeychain: false)
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: nil,
            legacyProjectID: Self.project,
            keychain: keychain
        )

        #expect(await store.getStoredRefreshToken() == nil)
        #expect(keychain.item(legacyKey)?.data == Data("other-bundle-refresh".utf8))
    }

    @Test func clearingRemovesCurrentAndLegacyItemsButNotTheSameAccountInAnotherService() async {
        let keychain = InMemoryKeychain()
        let legacyAccount = "stack-auth-access-\(Self.project)"
        let unrelated = InMemoryKeychain.Key(service: "unrelated", account: legacyAccount, accessGroup: Self.group)
        keychain.seed(unrelated, "unrelated-token", usesDataProtectionKeychain: true)
        keychain.seed(Self.legacy(legacyAccount), "legacy-access", usesDataProtectionKeychain: false)
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: Self.project,
            keychain: keychain
        )
        await store.setTokens(accessToken: "access", refreshToken: "refresh")

        await store.clearTokens()

        #expect(keychain.keys == [unrelated])
        #expect(keychain.item(unrelated)?.data == Data("unrelated-token".utf8))
    }

    @Test func aRefusedWriteReportsFailureSoTheFallbackStoreTakesOver() async {
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: nil,
            keychain: InMemoryKeychain(refusesAdds: true)
        )

        #expect(await store.trySetTokens(accessToken: "access", refreshToken: "refresh") == false)
    }

    @Test func compareAndSetSkipsAStaleRefreshToken() async {
        let keychain = InMemoryKeychain()
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: Self.group,
            legacyProjectID: nil,
            keychain: keychain
        )
        await store.setTokens(accessToken: "access", refreshToken: "current")

        await store.compareAndSet(compareRefreshToken: "stale", newRefreshToken: nil, newAccessToken: nil)
        #expect(keychain.item(Self.current("cmux-auth-refresh-token"))?.data == Data("current".utf8))

        await store.compareAndSet(compareRefreshToken: "current", newRefreshToken: nil, newAccessToken: nil)
        #expect(keychain.keys.isEmpty)
    }

    @Test func whereNoKeychainExistsReadsAreEmptyAndWritesFail() async {
        let store = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: nil,
            legacyProjectID: Self.project,
            keychain: UnavailableKeychain()
        )

        #expect(await store.trySetTokens(accessToken: "access", refreshToken: "refresh") == false)
        let fresh = KeychainStackTokenStore(
            service: Self.service,
            accessGroup: nil,
            legacyProjectID: Self.project,
            keychain: UnavailableKeychain()
        )
        #expect(await fresh.getStoredAccessToken() == nil)
        #expect(await fresh.getStoredRefreshToken() == nil)
        await fresh.clearTokens()
    }
}
