import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileClientIDRepository`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
@Suite struct MobileClientIDRepositoryTests {
    private func makeDefaults() -> (defaults: UserDefaults, open: @Sendable () -> UserDefaults) {
        makeTestDefaultsSuite("MobileClientIDRepositoryTests")
    }

    @Test func createsAndPersistsAUUIDOnFirstAccess() {
        let (defaults, open) = makeDefaults()
        let repository = MobileClientIDRepository(defaults: open)
        let id = repository.clientID
        #expect(UUID(uuidString: id) != nil)
        #expect(defaults.string(forKey: MobileClientIDRepository.defaultsKey) == id)
    }

    @Test func returnsTheSameIDAcrossReads() {
        let (_, open) = makeDefaults()
        let repository = MobileClientIDRepository(defaults: open)
        #expect(repository.clientID == repository.clientID)
    }

    @Test func reusesAPreviouslyPersistedID() {
        let (defaults, open) = makeDefaults()
        let existing = UUID().uuidString
        defaults.set(existing, forKey: MobileClientIDRepository.defaultsKey)
        let repository = MobileClientIDRepository(defaults: open)
        #expect(repository.clientID == existing)
    }

    @Test func replacesANonUUIDStoredValue() {
        let (defaults, open) = makeDefaults()
        defaults.set("not-a-uuid", forKey: MobileClientIDRepository.defaultsKey)
        let repository = MobileClientIDRepository(defaults: open)
        let id = repository.clientID
        #expect(UUID(uuidString: id) != nil)
        #expect(id != "not-a-uuid")
    }

    @Test func dogfoodLaunchUsesTheInjectedClientIdentity() {
        let (defaults, open) = makeDefaults()
        let expected = UUID().uuidString
        let repository = MobileClientIDRepository(
            defaults: open,
            environment: ["CMUX_DOGFOOD_CLIENT_ID": expected]
        )

        #expect(repository.clientID == expected)
        #expect(defaults.string(forKey: MobileClientIDRepository.defaultsKey) == expected)
    }

    @Test func invalidDogfoodIdentityDoesNotOverridePersistedClient() {
        let (defaults, open) = makeDefaults()
        let existing = UUID().uuidString
        defaults.set(existing, forKey: MobileClientIDRepository.defaultsKey)
        let repository = MobileClientIDRepository(
            defaults: open,
            environment: ["CMUX_DOGFOOD_CLIENT_ID": "not-a-uuid"]
        )

        #expect(repository.clientID == existing)
    }

    /// The repository is a checked `Sendable` value: copies used from many
    /// tasks at once all see the one persisted identifier (run under TSan).
    @Test func concurrentReadsShareThePersistedID() async {
        let (defaults, open) = makeDefaults()
        let existing = UUID().uuidString
        defaults.set(existing, forKey: MobileClientIDRepository.defaultsKey)
        let repository = MobileClientIDRepository(defaults: open, environment: [:])

        let ids = await withTaskGroup(of: String.self) { group in
            for _ in 0..<32 {
                group.addTask { repository.clientID }
            }
            var ids: Set<String> = []
            for await id in group { ids.insert(id) }
            return ids
        }

        #expect(ids == [existing])
    }
}
