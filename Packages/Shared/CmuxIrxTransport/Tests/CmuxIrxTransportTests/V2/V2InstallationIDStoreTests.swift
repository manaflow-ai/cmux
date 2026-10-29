import Foundation
import Testing

@testable import CmuxIrxTransport

struct V2InstallationIDStoreTests {
    @Test
    func preservesLegacyUuidBytes() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let service = "test.app.cmux-iroh-v2.installation"
        let original = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        access.seed(
            Data(original.utf8),
            service: service,
            account: "device-id",
            dataProtection: false
        )

        let store = V2InstallationIDStore(
            applicationNamespace: "test.app",
            access: access
        )

        #expect(try store.loadOrCreate() == original)
    }

    @Test
    func rejectsMalformedStoredUuid() throws {
        let access = V2KeychainTestAccess()
        let service = "test.app.cmux-iroh-v2.installation"
        access.seed(
            Data("not-a-uuid".utf8),
            service: service,
            account: "device-id",
            dataProtection: true
        )
        let store = V2InstallationIDStore(applicationNamespace: "test.app", access: access)

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate()
        }
    }

    @Test
    func createsAndReusesProtectedUuid() throws {
        let access = V2KeychainTestAccess()
        let store = V2InstallationIDStore(applicationNamespace: "test.app", access: access)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(UUID(uuidString: first) != nil)
        #expect(second == first)
        #expect(access.value(
            service: "test.app.cmux-iroh-v2.installation",
            account: "device-id",
            dataProtection: true
        ) != nil)
    }
}
