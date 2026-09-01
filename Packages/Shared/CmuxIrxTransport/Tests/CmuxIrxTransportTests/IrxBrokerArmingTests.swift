import CmuxIrohTransport
import Foundation
import Testing

@testable import CmuxIrxTransport

/// Warm-launch signing regression (08-27 INTERNAL wedge): a service built on
/// a cached binding must arm the broker client's per-request binding-proof
/// signing WITHOUT a network register(). An unarmed client sends proofless
/// mints that production 403s (binding_request_proof_required), permanently
/// wedging the phone until a cold registration.
enum IrxBrokerArmingSupport {
    static func makeService(
        identity: IrxIdentity,
        cacheDirectory: URL
    ) throws -> IrxBrokerService {
        try IrxBrokerService(
            configuration: .init(
                baseURL: URL(string: "https://example.invalid")!,
                clientNamespace: "test.cmux.arming",
                tag: "test",
                platform: .ios,
                displayName: nil,
                cacheDirectory: cacheDirectory
            ),
            identity: identity,
            accessTokenPair: { nil },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "irx-arming")
        )
    }

    static func identity() -> IrxIdentity {
        var seed = Data(count: 32)
        for index in 0..<32 { seed[index] = UInt8.random(in: 0...255) }
        return IrxIdentity(
            privateKeyData: seed,
            deviceID: "d-arming-test",
            appInstanceID: "a-arming-test"
        )
    }

    static func seedBinding(
        endpointIDHex: String,
        in directory: URL
    ) {
        IrxDiskCache<IrxBindingSnapshot>(
            fileURL: directory.appendingPathComponent("binding.json")
        ).save(
            IrxBindingSnapshot(
                bindingID: "b-cached-arming",
                deviceID: "d-arming-test",
                tag: "test",
                endpointIDHex: endpointIDHex,
                identityGeneration: 1,
                registeredAt: Date()
            )
        )
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-arming-\(UUID().uuidString)", isDirectory: true)
    }
}

@Suite("broker signing arming")
struct IrxBrokerArmingTests {
    @Test("a cached binding arms request signing at init, before any register()")
    func cachedBindingArmsSigning() async throws {
        let identity = IrxBrokerArmingSupport.identity()
        let dir = IrxBrokerArmingSupport.temporaryDirectory()
        IrxBrokerArmingSupport.seedBinding(
            endpointIDHex: identity.endpointIDHex, in: dir)
        let service = try IrxBrokerArmingSupport.makeService(
            identity: identity, cacheDirectory: dir)
        #expect(
            await service.hostBrokerClient.bindingAuthorizationID() == "b-cached-arming",
            "warm launch left the broker client unsigned; every mint will 403"
        )
    }

    @Test("a foreign endpoint's cached binding never arms signing")
    func foreignBindingDoesNotArm() async throws {
        let identity = IrxBrokerArmingSupport.identity()
        let dir = IrxBrokerArmingSupport.temporaryDirectory()
        IrxBrokerArmingSupport.seedBinding(
            endpointIDHex: String(repeating: "ab", count: 32), in: dir)
        let service = try IrxBrokerArmingSupport.makeService(
            identity: identity, cacheDirectory: dir)
        #expect(await service.hostBrokerClient.bindingAuthorizationID() == nil)
    }

    @Test("no cached binding leaves signing to register(), unarmed at init")
    func emptyCacheDoesNotArm() async throws {
        let service = try IrxBrokerArmingSupport.makeService(
            identity: IrxBrokerArmingSupport.identity(),
            cacheDirectory: IrxBrokerArmingSupport.temporaryDirectory())
        #expect(await service.hostBrokerClient.bindingAuthorizationID() == nil)
    }
}
