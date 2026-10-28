import Dispatch
import Foundation
import Testing
import dnssd
@testable import CmuxIrohTransport

/// The types that left `@unchecked Sendable` keep their behavior when many threads
/// call them at once. Run under `--sanitize=thread` as well.
@Suite
struct CmxIrohSharedStateConcurrencyTests {
    private static let alias = String(repeating: "0", count: 24) + "0000002a"

    @Test
    func concurrentDuplicateBrowseOffersYieldOneEventUntilConsumed() async {
        let (events, continuation) = AsyncStream.makeStream(
            of: CmxIrohBonjourRawBrowseEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        let ingress = CmxIrohBonjourBrowseIngress(continuation: continuation)

        DispatchQueue.concurrentPerform(iterations: 256) { _ in
            Self.offerAdd(ingress)
        }
        let key = CmxIrohBonjourRawBrowseEvent.Key.service(
            CmxIrohBonjourServiceID(serviceName: Self.alias, interfaceIndex: 4),
            added: true
        )
        Self.offerAdd(ingress)
        ingress.consumed(key)
        Self.offerAdd(ingress)
        ingress.finish()

        var keys: [CmxIrohBonjourRawBrowseEvent.Key] = []
        for await event in events {
            keys.append(event.key)
        }
        #expect(keys == [key, key])
    }

    @Test
    func allowlistDropsOffersFromAnyThread() async {
        let (events, continuation) = AsyncStream.makeStream(
            of: CmxIrohBonjourRawBrowseEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        let ingress = CmxIrohBonjourBrowseIngress(
            continuation: continuation,
            serviceNameAllowlist: [String(repeating: "f", count: 32)]
        )

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            Self.offerAdd(ingress)
        }
        ingress.finish()

        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 0)
    }

    @Test
    func suiteStoreRoundTripsAcrossThreadsAndInstances() throws {
        let suiteName = "CmxIrohSharedStateConcurrencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try #require(CmxIrohUserDefaultsInstallStateStore(suiteName: suiteName))

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            store.set("value-\(index)", forKey: "key-\(index)")
        }

        let reopened = try #require(CmxIrohUserDefaultsInstallStateStore(suiteName: suiteName))
        for index in 0 ..< 64 {
            #expect(reopened.string(forKey: "key-\(index)") == "value-\(index)")
        }
        #expect(defaults.string(forKey: "key-7") == "value-7")
        store.set(nil, forKey: "key-7")
        #expect(reopened.string(forKey: "key-7") == nil)
    }

    @Test
    func suiteStoreRefusesTheGlobalDomain() {
        #expect(CmxIrohUserDefaultsInstallStateStore(suiteName: "NSGlobalDomain") == nil)
    }

    private static func offerAdd(_ ingress: CmxIrohBonjourBrowseIngress) {
        ingress.offer(
            flags: DNSServiceFlags(kDNSServiceFlagsAdd),
            interfaceIndex: 4,
            errorCode: DNSServiceErrorType(kDNSServiceErr_NoError),
            serviceName: Self.alias,
            regtype: "\(CmxIrohLANAdvertisement.serviceType).",
            domain: CmxIrohLANAdvertisement.domain
        )
    }
}
