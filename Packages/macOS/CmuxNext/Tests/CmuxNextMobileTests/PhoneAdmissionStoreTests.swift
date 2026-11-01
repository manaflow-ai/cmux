import CmuxNextCompat
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
        let seal = MobileHostMemoryPairingSeal()
        let store = MobileHostPairedStore(seal: seal)
        store.select(userID: "one")
        await store.attach(directory: directory)
        let generation = store.generation
        try await store.change(for: "one", generation: generation) { $0.approve(Self.phone, at: Date()) }
        #expect(store.trusts(Self.phone))
        let restored = MobileHostPairedStore(seal: seal)
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
        store.select(userID: "one")
        await store.reload()
        #expect(!store.trusts(Self.phone))
    }

    @Test func failedSaveAndCorruptFileGrantNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked".utf8).write(to: root)
        let store = MobileHostPairedStore(seal: MobileHostMemoryPairingSeal())
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

    /// Invoke removal inside the sealed read, after bytes were read but before publication.
    /// No sleeps, blocked threads, or scheduling assumptions are needed.
    /// Checked `Sendable` (no `@unchecked`): its only state is two `let`s, a Sendable seal and a `Mutex`.
    private final class ReadHookSeal: MobileHostPairingSealStore {
        let backing = MobileHostMemoryPairingSeal()
        let hook = Mutex<(@Sendable () -> Void)?>(nil)
        func digest() -> Data? {
            let callback = hook.withLock { hook in
                let callback = hook
                hook = nil
                return callback
            }
            callback?()
            return backing.digest()
        }
        func setDigest(_ digest: Data) -> Bool { backing.setDigest(digest) }
        func clearDigest() -> Bool { backing.clearDigest() }
    }

    @Test func removalDuringReloadStaysRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = ReadHookSeal()
        let file = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        var seeded = MobileHostPairedDevices(userID: "one")
        seeded.approve(Self.phone, at: Date())
        try file.save(seeded)
        #expect(file.load(userID: "one").decision(for: Self.phone) == .trusted)
        let store = MobileHostPairedStore(seal: seal)
        store.select(userID: "one")
        seal.hook.withLock { $0 = {
            #expect(store.current == nil)
            store.forget(id: Self.phone.phoneDeviceID, transport: .iroh)
        } }
        await store.attach(directory: directory)
        await store.reload() // also drains the queued removal
        #expect(!store.trusts(Self.phone))
        // The restored store makes a new list file: it remembers no digest of this run, as a relaunch.
        let restored = MobileHostPairedStore(seal: seal)
        restored.select(userID: "one")
        await restored.attach(directory: directory)
        #expect(!restored.trusts(Self.phone))
    }

    @Test func restoredOlderSealedFileDoesNotRestoreRemovedPhone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let file = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        let store = MobileHostPairedStore(seal: seal)
        store.select(userID: "one")
        await store.attach(directory: directory)
        try await store.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        #expect(store.trusts(Self.phone))
        let older = try Data(contentsOf: file.file)
        store.forget(id: Self.phone.phoneDeviceID, transport: .iroh)
        await store.reload()
        #expect(!store.trusts(Self.phone))
        try older.write(to: file.file, options: .atomic)
        // A relaunch retains only the Keychain seal: the restored store's new list file remembers no digest.
        let restored = MobileHostPairedStore(seal: seal)
        restored.select(userID: "one")
        await restored.attach(directory: directory)
        #expect(!restored.trusts(Self.phone))
    }

    @Test func inFlightReapprovalCannotUndoRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostPairedStore(seal: MobileHostMemoryPairingSeal())
        store.select(userID: "one")
        await store.attach(directory: directory)
        try await store.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        let entered = AsyncStream<Void>.makeStream()
        let saving = Task {
            try await store.change(for: "one") { list in
                entered.continuation.yield(())
                Thread.sleep(forTimeInterval: 0.05)
                var rekeyed = Self.phone
                rekeyed.identityKey = String(repeating: "c", count: 64)
                list.approve(rekeyed, at: Date())
            }
        }
        var enteredEvents = entered.stream.makeAsyncIterator()
        _ = try #require(await enteredEvents.next())
        store.forget(id: Self.phone.phoneDeviceID, transport: .iroh)
        try await saving.value
        await store.reload()
        #expect(!store.trusts(Self.phone))
        var rekeyed = Self.phone
        rekeyed.identityKey = String(repeating: "c", count: 64)
        #expect(!store.trusts(rekeyed))
    }

    @Test func aRemovalRightAfterAnApprovalInTheSameTurnWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostPairedStore(seal: MobileHostMemoryPairingSeal())
        store.select(userID: "one")
        await store.attach(directory: directory)
        let saved = AsyncStream<(any Error)?>.makeStream()
        // The legacy Allow, then Settings > Mobile's Remove, with nothing run between them.
        store.submit(for: "one", generation: store.generation, { $0.approve(Self.phone, at: Date()) }) {
            saved.continuation.yield($0)
        }
        store.forget(id: Self.phone.phoneDeviceID, transport: .iroh)
        var results = saved.stream.makeAsyncIterator()
        _ = await results.next()
        await store.reload()
        #expect(!store.trusts(Self.phone))
    }

    @Test func aValidUnsealedJsonFileIsNotTrustedAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var list = MobileHostPairedDevices(userID: "one")
        list.approve(Self.phone, at: Date())
        let data = try JSONEncoder().encode(list)
        try data.write(to: directory.appendingPathComponent("paired-devices.json"))
        let restored = MobileHostPairedStore(seal: MobileHostMemoryPairingSeal())
        restored.select(userID: "one")
        await restored.attach(directory: directory)
        #expect(!restored.trusts(Self.phone))
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
