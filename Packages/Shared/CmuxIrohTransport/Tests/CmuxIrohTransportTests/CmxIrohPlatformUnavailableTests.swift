import Foundation
import Testing

@testable import CmuxIrohTransport

/// The stand-ins a build without the Apple frameworks gets (Linux): each
/// fails closed with its framework's own error, never an unprotected or
/// silent fallback.
@Suite
struct CmxIrohPlatformUnavailableTests {
    #if !canImport(Security)
    @Test
    func keychainCredentialStoreRefusesEveryOperation() async {
        let store = CmxIrohKeychainCredentialStore()
        let unavailable = CmxIrohKeychainCredentialStoreError(status: -25_291)
        await #expect(throws: unavailable) { try await store.read(account: "a") }
        await #expect(throws: unavailable) {
            try await store.write(Data([1]), account: "a", accessibility: .afterFirstUnlockThisDeviceOnly)
        }
        await #expect(throws: unavailable) { try await store.delete(account: "a") }
        await #expect(throws: unavailable) { try await store.deleteAll() }
    }

    @Test
    func keychainIdentityStoreRefusesEveryOperation() async {
        let store = CmxIrohKeychainIdentityStore()
        let unavailable = CmxIrohKeychainIdentityStoreError(status: -25_291)
        await #expect(throws: unavailable) { try await store.read(account: "a") }
        await #expect(throws: unavailable) { try await store.write(Data([1]), account: "a") }
        await #expect(throws: unavailable) { try await store.delete(account: "a") }
        await #expect(throws: unavailable) { try await store.deleteAll() }
    }
    #endif

    @Test
    func identityStoreRandomSecretIsAFreshSeed() throws {
        let first = try CmxIrohKeychainIdentityStore.randomSecretBytes()
        let second = try CmxIrohKeychainIdentityStore.randomSecretBytes()
        #expect(first.count == 32)
        #expect(first != second)
        _ = try CmxIrohEndpointSigningKey(secretKeyBytes: first)
    }

    #if !canImport(dnssd)
    @Test
    func bonjourPublisherAcceptsAnEmptySetAndEmitsNothing() async throws {
        let publisher = CmxIrohSystemBonjourPublisher()
        try await publisher.replace(with: [])
        var events: [CmxIrohBonjourPublisherEvent] = []
        for await event in await publisher.events() {
            events.append(event)
        }
        #expect(events.isEmpty)
    }

    @Test
    func bonjourBrowserReportsServiceNotRunning() async {
        let browser = CmxIrohSystemBonjourBrowser()
        var events: [CmxIrohBonjourBrowserEvent] = []
        for await event in await browser.events() {
            events.append(event)
        }
        #expect(events == [.failed(-65_742)])
    }
    #endif

    #if !canImport(IrohLib)
    @Test
    func endpointFactoryRefusesToBind() async throws {
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 1, count: 32)),
            alpns: [Data("cmux/test/1".utf8)],
            managedRelayURLs: [],
            relays: []
        )
        await #expect(throws: CmxIrohEndpointUnavailableError()) {
            _ = try await CmxIrohLibEndpointFactory().bind(configuration: configuration)
        }
    }
    #endif
}
