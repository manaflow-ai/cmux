import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct PhoneAdmissionTests {
    nonisolated static let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Phone",
                                             identityKey: String(repeating: "a", count: 64), approvalKey: "", transport: .iroh)

    static func store(at directory: URL) async -> MobileHostPairedStore {
        let store = MobileHostPairedStore()
        store.select(userID: "one")
        await store.attach(directory: directory)
        return store
    }

    @Test func allowIsSavedOnceAndRemoveClosesOnlyThatTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let removed = AsyncStream<String>.makeStream()
        let admission = PhoneAdmission(phones: store, disconnect: { removed.continuation.yield($0) })
        var asks = 0
        admission.ask = { _, user in asks += 1; #expect(user == "one"); return true }
        #expect(await admission.decide(Self.phone))
        #expect(await admission.decide(Self.phone))
        #expect(asks == 1)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("paired-devices.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let hostd = MobileHostPairRequest(phoneDeviceID: "hostd", name: "iOS", identityKey: "i", approvalKey: "a")
        try await store.change(for: "one") { $0.approve(hostd, at: Date()) }
        try await store.change(for: "one") { $0.remove(hostd.phoneDeviceID) }
        try await store.change(for: "one") { $0.remove(Self.phone.phoneDeviceID, transport: .iroh) }
        var events = removed.stream.makeAsyncIterator()
        #expect(await events.next() == Self.phone.phoneDeviceID)
        #expect(!store.trusts(Self.phone))
        #expect(await admission.decide(Self.phone))
        #expect(asks == 2)
    }

    @Test func aQuestionCannotGrantAfterSwitchingAwayAndBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        let questions = AsyncStream<CheckedContinuation<Bool, Never>>.makeStream()
        admission.ask = { _, _ in await withCheckedContinuation { questions.continuation.yield($0) } }
        // task-owner: this test owns and awaits its pending admission
        let first = Task { await admission.decide(Self.phone) }
        var events = questions.stream.makeAsyncIterator()
        let answer = try #require(await events.next())
        store.select(userID: "two")
        await store.reload()
        // A second user cannot join the first user's outstanding question.
        store.select(userID: "one")
        await store.reload()
        answer.resume(returning: true)
        #expect(await !first.value)
        #expect(!store.trusts(Self.phone))
    }

    @Test func denialsAreBoundedAndBelongToTheQuestionUser() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        var asks = 0
        var time = ContinuousClock.now
        admission.now = { time }
        admission.ask = { _, _ in asks += 1; return false }
        #expect(await !admission.decide(Self.phone))
        #expect(await !admission.decide(Self.phone))
        #expect(asks == 1)
        time = time.advanced(by: .seconds(601))
        #expect(await !admission.decide(Self.phone))
        #expect(asks == 2)
        store.select(userID: "two")
        await store.reload()
        #expect(await !admission.decide(Self.phone))
        #expect(asks == 3)
        store.select(userID: nil)
        #expect(await !admission.decide(Self.phone))
        #expect(asks == 3)
    }

    @Test func theQuestionBindsUserAndKeyAndHasNoReturnAllow() {
        let spec = PhoneAdmission.spec(Self.phone, user: "one")
        #expect(spec.defaultButton == nil)
        #expect(spec.cancelButton?.id == "deny")
        #expect(spec.buttons.first { $0.id == "allow" }?.key == nil)
        #expect(spec.lines.contains { $0.contains("one") })
        #expect(spec.lines.contains { $0.contains(Self.phone.identityKey) })
        #expect(spec.identifier == IPhoneHostService.phoneAccessDialogIdentifier)
    }

    @Test func concurrentConnectionsShareAQuestionAndTheQueueIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        let questions = AsyncStream<CheckedContinuation<Bool, Never>>.makeStream()
        var asks = 0
        admission.ask = { _, _ in
            asks += 1
            return await withCheckedContinuation { questions.continuation.yield($0) }
        }
        // task-owner: every pending question belongs to this test and is answered below
        let first = Task { await admission.decide(Self.phone) }
        var events = questions.stream.makeAsyncIterator()
        let firstAnswer = try #require(await events.next())
        let repeated = Task { await admission.decide(Self.phone) }
        var other = Self.phone
        other.phoneDeviceID = "other"
        let secondPhone = other
        let second = Task { await admission.decide(secondPhone) }
        let secondAnswer = try #require(await events.next())
        var third = Self.phone
        third.phoneDeviceID = "third"
        #expect(await !admission.decide(third))
        #expect(asks == 2)
        firstAnswer.resume(returning: true)
        secondAnswer.resume(returning: false)
        #expect(await first.value)
        #expect(await repeated.value)
        #expect(await !second.value)
        #expect(asks == 2)
    }

    @Test func localRowsRemainRemovableWhenIPhoneHostIsOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = IPhoneHostService()
        host.pairedStore.select(userID: "one")
        await host.pairedStore.attach(directory: directory)
        try await host.pairedStore.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        host.paired = host.pairedStore.current
        #expect(host.pageJSON["phones"]?.arrayValue?.first?["removable"]?.boolValue == true)
        await host.removePhone(id: "iroh:" + Self.phone.phoneDeviceID)
        #expect(!host.pairedStore.trusts(Self.phone))
    }
}
