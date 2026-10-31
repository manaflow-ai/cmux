import AppKit
import CmuxNextDesign
import CmuxNextCompat
@testable import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

@MainActor @Suite(.timeLimit(.minutes(1))) struct PhoneAdmissionTests {
    nonisolated static let phone = MobileHostPairRequest(phoneDeviceID: String(repeating: "a", count: 64), name: "Phone",
                                             identityKey: String(repeating: "a", count: 64), approvalKey: "", transport: .iroh)

    static func store(at directory: URL) async -> MobileHostPairedStore {
        let store = MobileHostPairedStore(seal: MobileHostMemoryPairingSeal())
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
        admission.ask = { _, user in asks += 1; #expect(user == "one"); return .allow }
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
        let questions = AsyncStream<CheckedContinuation<PhoneAdmission.PromptResult, Never>>.makeStream()
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
        answer.resume(returning: .allow)
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
        admission.ask = { _, _ in asks += 1; return .deny }
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
        #expect(spec.cancelButton?.id == "cancel")
        #expect(spec.buttons.first { $0.id == "deny" }?.role == .normal)
        #expect(spec.buttons.first { $0.id == "allow" }?.key == nil)
        #expect(spec.lines.contains { $0.contains("one") })
        #expect(spec.lines.contains { $0.contains(Self.phone.identityKey) })
        #expect(spec.identifier == IPhoneHostService.phoneAccessDialogIdentifier)
    }

    @Test func promptUsesAccountEmailWhenAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        admission.accountName = { "demo@example.invalid" }
        var shown = ""
        admission.ask = { _, account in shown = account; return .unavailable }
        #expect(await !admission.decide(Self.phone))
        #expect(shown == "demo@example.invalid")
    }

    @Test func concurrentConnectionsShareAQuestionAndTheQueueIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        let questions = AsyncStream<CheckedContinuation<PhoneAdmission.PromptResult, Never>>.makeStream()
        var asks = 0
        var quiet = 0
        admission.quiet = { quiet += 1 }
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
        firstAnswer.resume(returning: .allow)
        #expect(await first.value)
        #expect(quiet == 0)
        secondAnswer.resume(returning: .deny)
        #expect(await repeated.value)
        #expect(await !second.value)
        #expect(asks == 2)
        #expect(quiet == 1)
    }

    @Test func timeoutAndDismissalDoNotCreateDenialCooldown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        var answers: [PhoneAdmission.PromptResult] = [.unavailable, .unavailable, .allow]
        var asks = 0
        admission.ask = { _, _ in
            asks += 1
            return answers.removeFirst()
        }
        #expect(await !admission.decide(Self.phone)) // timeout
        #expect(await !admission.decide(Self.phone)) // dismissal
        #expect(await admission.decide(Self.phone))
        #expect(asks == 3)
    }

    /// Each prompt owns its center, event subscription and task. Waiting for its opened
    /// event avoids scheduler assumptions and never selects another test's queued dialog.
    private static func withPrompt(
        keyWindow: @escaping @MainActor () -> NSWindow? = { nil },
        answer: (CmuxDialogCenter, CmuxDialogCenter.Record) throws -> Void
    ) async throws -> PhoneAdmission.PromptResult {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        let opened = AsyncStream<CmuxDialogCenter.Record>.makeStream()
        let observer = center.observe { event in
            if case .opened(let record) = event { opened.continuation.yield(record) }
        }
        // task-owner: answered below; even a failed assertion dismisses the prompt and
        // cancels its timeout before the test exits. The headless host creates no panels.
        let task = Task {
            await PhoneAdmission.askOnThisMac(Self.phone, user: "demo", timeout: .seconds(120),
                                              center: center, keyWindow: keyWindow)
        }
        defer {
            center.dismissAll()
            center.stopObserving(observer)
            opened.continuation.finish()
            task.cancel()
        }
        var events = opened.stream.makeAsyncIterator()
        let record = try #require(await events.next())
        #expect(record.spec.identifier == PhoneAdmission.dialogIdentifier)
        #expect(record.visible)
        try answer(center, record)
        let result = await task.value
        #expect(center.records.isEmpty)
        #expect(host.shown.isEmpty)
        return result
    }

    @Test func missingKeyWindowUsesAppModalAndDoesNotDeny() async throws {
        // Inject the missing window instead of changing NSApp's focus or requiring the
        // fleet host to grant one. The production scope-selection path is unchanged.
        let result = try await Self.withPrompt(keyWindow: { nil }) { center, record in
            #expect(record.scope == "app")
            try #require(center.dismiss(record.id))
        }
        #expect(result == .unavailable)
    }

    @Test func timeoutIsUnavailableAndDoesNotCreateDenial() async throws {
        let host = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: host)
        defer { center.dismissAll() }
        let result = await PhoneAdmission.askOnThisMac(Self.phone, user: "demo", timeout: .milliseconds(1),
                                                       center: center, keyWindow: { nil })
        #expect(result == .unavailable)
        #expect(center.records.isEmpty)
        #expect(host.shown.isEmpty)
    }

    @Test func dismissalIsUnavailableAndDoesNotCreateDenial() async throws {
        let result = try await Self.withPrompt { center, record in
            try #require(center.dismiss(record.id))
        }
        #expect(result == .unavailable)
    }

    @Test func escapeIsUnavailableAndDoesNotCreateDenial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let admission = PhoneAdmission(phones: store, disconnect: { _ in })
        let result = try await Self.withPrompt { center, record in
            try #require(center.key(.escape, in: record.id))
        }
        #expect(result == .unavailable)
        admission.ask = { _, _ in result }
        #expect(await !admission.decide(Self.phone))
        admission.ask = { _, _ in .allow }
        #expect(await admission.decide(Self.phone), "Escape must leave the next connection free to ask")
    }

    @Test func commandPeriodAndCancelAreUnavailable() async throws {
        let keyboard = try await Self.withPrompt { center, record in
            try #require(center.key(.character("."), modifiers: .command, in: record.id))
        }
        let button = try await Self.withPrompt { center, record in
            try #require(center.press(record.id, button: "cancel"))
        }
        #expect(keyboard == .unavailable)
        #expect(button == .unavailable)
    }

    @Test func explicitDenyRecordsDenial() async throws {
        let result = try await Self.withPrompt { center, record in
            try #require(center.press(record.id, button: "deny"))
        }
        #expect(result == .deny)
    }

    /// Revoking a phone hands the next hostd the list without it at once, before the store's
    /// observer task runs: a hostd restart in between must not trust the revoked phone again.
    @Test func revokeUpdatesTheNextHostdsListAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        let hostd = MobileHostPairRequest(phoneDeviceID: "hostd-phone", name: "iOS", identityKey: "i", approvalKey: "a")
        try await store.change(for: "one") { $0.approve(hostd, at: Date()) }
        let host = IPhoneHostService(pairedStore: store)
        host.revokePhone(id: hostd.phoneDeviceID)
        let line = try #require(host.supervisor.devicesForNextHostd(), "no list for the next hostd")
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let ids = (object["devices"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        #expect(!ids.contains(hostd.phoneDeviceID), "the next hostd still trusts the revoked phone: \(object)")
    }

    /// Removing a Phone Access phone ends its live sessions before removePhone returns.
    @Test func removingAnIrohPhoneDisconnectsItBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        try await store.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        let host = IPhoneHostService(pairedStore: store)
        let disconnected = Mutex<[String]>([])
        host.followPhoneAccess(PhoneAccessGate(), disconnect: { endpoint in disconnected.withLock { $0.append(endpoint) } })
        await host.removePhone(id: "iroh:" + Self.phone.phoneDeviceID)
        #expect(disconnected.withLock { $0 }.first == Self.phone.phoneDeviceID)
        #expect(!store.trusts(Self.phone))
    }

    @Test func removalCancelsPendingRekeyAndRejectsLateAllow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await Self.store(at: directory)
        try await store.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        var rekeyed = Self.phone
        rekeyed.identityKey = String(repeating: "c", count: 64)

        let host = IPhoneHostService(pairedStore: store)
        let gate = PhoneAccessGate()
        host.followPhoneAccess(gate, disconnect: { _ in })
        let admission = try #require(host.phoneAdmission)
        let dialogHost = CmuxDialogHeadlessHost()
        let center = CmuxDialogCenter(host: dialogHost)
        let opened = AsyncStream<CmuxDialogCenter.Record>.makeStream()
        let observer = center.observe { event in
            if case .opened(let record) = event { opened.continuation.yield(record) }
        }
        admission.ask = { phone, account in
            await PhoneAdmission.askOnThisMac(phone, user: account, timeout: .seconds(120),
                                              center: center, keyWindow: { nil })
        }
        admission.dismissAsk = { _, _ in center.dismissAll() }
        defer {
            center.dismissAll()
            center.stopObserving(observer)
            opened.continuation.finish()
        }
        // task-owner: the prompt is removed before the late Allow press below
        let pending = Task { await gate.admits(rekeyed) }
        var events = opened.stream.makeAsyncIterator()
        let record = try #require(await events.next())
        await host.removePhone(id: "iroh:" + Self.phone.phoneDeviceID)
        #expect(center.records.isEmpty)
        #expect(!center.press(record.id, button: "allow"))
        #expect(await !pending.value)
        #expect(!store.trusts(Self.phone))
        #expect(!store.trusts(rekeyed))
    }

    @Test func localRowsRemainRemovableWhenIPhoneHostIsOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = IPhoneHostService(pairedStore: MobileHostPairedStore(seal: MobileHostMemoryPairingSeal()))
        host.pairedStore.select(userID: "one")
        await host.pairedStore.attach(directory: directory)
        try await host.pairedStore.change(for: "one") { $0.approve(Self.phone, at: Date()) }
        #expect(host.pageJSON["phones"]?.arrayValue?.first?["removable"]?.boolValue == true)
        #expect(host.pageJSON["phones"]?.arrayValue?.first?["title"]?.stringValue == "Phone · cmux next")
        #expect(host.pageJSON["phones"]?.arrayValue?.first?["transport"]?.stringValue == "iroh")
        #expect(host.pageJSON["phones"]?.arrayValue?.first?["path"]?.isNull == true)
        await host.removePhone(id: "iroh:" + Self.phone.phoneDeviceID)
        #expect(!host.pairedStore.trusts(Self.phone))
        await host.pairedStore.reload()
    }
}
