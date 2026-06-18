import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileClientIDRepository`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
@Suite struct MobileClientIDRepositoryTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MobileClientIDRepositoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func createsAndPersistsAUUIDOnFirstAccess() {
        let defaults = makeDefaults()
        let repository = MobileClientIDRepository(defaults: defaults)
        let id = repository.clientID
        #expect(UUID(uuidString: id) != nil)
        #expect(defaults.string(forKey: MobileClientIDRepository.defaultsKey) == id)
    }

    @Test func returnsTheSameIDAcrossReads() {
        let defaults = makeDefaults()
        let repository = MobileClientIDRepository(defaults: defaults)
        #expect(repository.clientID == repository.clientID)
    }

    @Test func reusesAPreviouslyPersistedID() {
        let defaults = makeDefaults()
        let existing = UUID().uuidString
        defaults.set(existing, forKey: MobileClientIDRepository.defaultsKey)
        let repository = MobileClientIDRepository(defaults: defaults)
        #expect(repository.clientID == existing)
    }

    @Test func replacesANonUUIDStoredValue() {
        let defaults = makeDefaults()
        defaults.set("not-a-uuid", forKey: MobileClientIDRepository.defaultsKey)
        let repository = MobileClientIDRepository(defaults: defaults)
        let id = repository.clientID
        #expect(UUID(uuidString: id) != nil)
        #expect(id != "not-a-uuid")
    }
}
