import Foundation
import Testing
@testable import CmuxNextMobile

struct PhoneAdmissionStoreTests {
    static let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Phone",
                                             identityKey: String(repeating: "a", count: 64), approvalKey: "", transport: .iroh)

    @Test func unwiredAdmissionRefusesEveryPhone() async {
        let gate = PhoneAccessGate()
        #expect(await !gate.admits(Self.phone))
        #expect(!gate.stillAllows(Self.phone))
    }

    @Test func persistenceAndUserOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostPairedStore()
        store.select(userID: "one")
        await store.attach(directory: directory)
        let generation = store.generation
        try await store.change(for: "one", generation: generation) { $0.approve(Self.phone, at: Date()) }
        #expect(store.trusts(Self.phone))
        let restored = MobileHostPairedStore()
        restored.select(userID: "one")
        await restored.attach(directory: directory)
        #expect(restored.trusts(Self.phone))
        store.select(userID: "two")
        #expect(!store.trusts(Self.phone))
        await store.reload()
        await #expect(throws: (any Error).self) {
            try await store.change(for: "one", generation: generation) { $0.approve(Self.phone, at: Date()) }
        }
        #expect(store.current?.devices.isEmpty == true)
        store.select(userID: "one")
        await store.reload()
        await #expect(throws: (any Error).self) {
            try await store.change(for: "one", generation: generation) { $0.approve(Self.phone, at: Date()) }
        }
        store.select(userID: nil)
        #expect(store.current == nil && !store.trusts(Self.phone))
    }

    @Test func failedSaveAndCorruptFileGrantNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked".utf8).write(to: root)
        let store = MobileHostPairedStore()
        store.select(userID: "one")
        await store.attach(directory: root)
        await #expect(throws: (any Error).self) {
            try await store.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        }
        #expect(!store.trusts(Self.phone))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("paired-devices.json"))
        await store.reload()
        #expect(!store.trusts(Self.phone))
    }

    @Test func transportsNeverShareHostdAuthority() throws {
        var list = MobileHostPairedDevices(userID: "one")
        list.approve(Self.phone, at: Date())
        let hostd = MobileHostPairRequest(phoneDeviceID: Self.phone.phoneDeviceID, name: "iOS",
                                          identityKey: Self.phone.identityKey, approvalKey: "approval")
        #expect(list.decision(for: hostd) == .ask)
        let line = try #require(try JSONSerialization.jsonObject(with: MobileHostLaunch.devicesLine(list)) as? [String: Any])
        #expect((line["devices"] as? [[String: Any]])?.isEmpty == true)
        #expect((list.approversParams(macDevice: "m")["approvers"] as? [[String: String]])?.isEmpty == true)
        list.approve(hostd, at: Date())
        list.remove(Self.phone.phoneDeviceID, transport: .iroh)
        #expect(list.decision(for: hostd) == .trusted)
        #expect(list.decision(for: Self.phone) == .ask)
        let old = #"{"userID":"one","devices":[{"id":"old","name":"iOS","identityKey":"i","approvalKey":"a","pairedAt":0}],"denied":[]}"#
        #expect(try JSONDecoder().decode(MobileHostPairedDevices.self, from: Data(old.utf8)).devices.first?.transport == .hostd)
    }
}
