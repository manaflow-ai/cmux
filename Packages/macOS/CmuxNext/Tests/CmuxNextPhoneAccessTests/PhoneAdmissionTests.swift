@testable import CmuxNextPhoneAccess
import CmuxNextMobile
import Foundation
import Testing

/// `phone.newDevices`: a phone on the allowed list gets in; a new one asks
/// once on this Mac (Allow lists it, Deny holds for ten minutes); Any Phone on
/// My Account lets it in and lists it; Remove closes its sessions and makes it ask again.
/// The list is Settings > Mobile's one ``MobileHostPairedStore``, an Iroh phone an `.iroh` entry.
@Suite(.serialized)
@MainActor
struct PhoneAdmissionTests {
    /// The endpoint keys whose sessions the admission closed.
    actor Closed {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    private static func admission(user: String? = "user-1") -> (PhoneAdmission, URL, Closed) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-admission-\(UUID().uuidString)")
        let store = MobileHostPairedStore()
        store.attach(directory: directory)
        let closed = Closed()
        let admission = PhoneAdmission(phones: store) { await closed.add($0) }
        // The iPhone host's account sets the user (one owner); the admission only reads it.
        store.load(userID: user)
        return (admission, directory, closed)
    }

    private static func phone(_ id: String, _ name: String) -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: id, name: name, identityKey: id, approvalKey: "", transport: .iroh)
    }

    private static let phone = phone("dev-1", "Leo's iPhone")

    private static func listed(_ admission: PhoneAdmission) -> [String] {
        admission.phones.current?.devices.map(\.id) ?? []
    }

    @Test func allowListsThePhoneAndAsksOnce() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        admission.ask = { _ in asked += 1; return true }
        #expect(await admission.decide(Self.phone))
        #expect(await admission.decide(Self.phone))
        #expect(asked == 1)
        #expect(admission.phones.current?.devices.map(\.transport) == [.iroh])
        #expect(admission.phones.current?.devices.first?.approvalKey == "")
    }

    @Test func denyHoldsForTenMinutes() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        var now = ContinuousClock.now
        admission.clock = { now }
        admission.ask = { _ in asked += 1; return false }
        #expect(!(await admission.decide(Self.phone)))
        now += .seconds(60)
        #expect(!(await admission.decide(Self.phone)))
        #expect(asked == 1)
        now += PhoneAdmission.denialHold
        _ = await admission.decide(Self.phone)
        #expect(asked == 2)
        #expect(Self.listed(admission).isEmpty)
    }

    /// The hold starts when Deny is pressed, not when the question opened.
    @Test func theHoldStartsAtTheAnswer() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        var now = ContinuousClock.now
        admission.clock = { now }
        admission.ask = { _ in
            asked += 1
            now += PhoneAdmission.denialHold  // the dialog sat open for the whole hold
            return false
        }
        #expect(!(await admission.decide(Self.phone)))
        now += .seconds(1)
        #expect(!(await admission.decide(Self.phone)))
        #expect(asked == 1)
    }

    /// A burst of new phones raises at most `questionCap` questions; the rest are turned away unasked.
    @Test func questionsAreCapped() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [String] = []
        var release: [CheckedContinuation<Void, Never>] = []
        admission.ask = { device in
            asked.append(device.phoneDeviceID)
            await withCheckedContinuation { release.append($0) }
            return true
        }
        let phones = (1...4).map { Self.phone("dev-\($0)", "Phone \($0)") }
        let first = Task { await admission.decide(phones[0]) }
        let second = Task { await admission.decide(phones[1]) }
        while release.count < 2 { await Task.yield() }
        #expect(!(await admission.decide(phones[2])))
        #expect(!(await admission.decide(phones[3])))
        release.forEach { $0.resume() }
        #expect(await first.value)
        #expect(await second.value)
        #expect(Set(asked) == ["dev-1", "dev-2"])
        // A turned-away phone was not denied: it is asked once a question is free.
        admission.ask = { device in asked.append(device.phoneDeviceID); return true }
        #expect(await admission.decide(phones[2]))
        #expect(asked.last == "dev-3")
    }

    /// An Allow that cannot be saved lets nothing in (an unlisted phone could not be removed).
    @Test func anAllowThatCannotBeSavedRefuses() async throws {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)  // a file where the folder must go
        admission.ask = { _ in true }
        #expect(!(await admission.decide(Self.phone)))
        #expect(Self.listed(admission).isEmpty)
    }

    @Test func anyPhoneOnTheAccountGetsInAndIsListed() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.mode = .account
        admission.ask = { _ in Issue.record("asked in account mode"); return false }
        #expect(await admission.decide(Self.phone))
        #expect(Self.listed(admission) == ["dev-1"])
    }

    /// Settings > Mobile's Remove (`IPhoneHostService.revokePhone`, which edits the shared store)
    /// closes the phone's open sessions, and its next connection asks again. A hostd entry's
    /// removal closes no Iroh session.
    @Test func removeClosesTheSessionsAndAsksAgain() async throws {
        let (admission, directory, closed) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var answers = [true, false]
        admission.ask = { _ in answers.removeFirst() }
        #expect(await admission.decide(Self.phone))
        let hostd = MobileHostPairRequest(phoneDeviceID: "p1", name: "iPhone", identityKey: "aa", approvalKey: "bb")
        try admission.phones.change { $0.approve(hostd, at: Date()) }
        try admission.phones.change { $0.remove("p1") }
        try admission.phones.change { $0.remove(Self.phone.phoneDeviceID) }
        while await closed.ids.isEmpty { await Task.yield() }
        #expect(await closed.ids == [Self.phone.phoneDeviceID])
        #expect(Self.listed(admission).isEmpty)
        #expect(!(await admission.decide(Self.phone)))
        #expect(answers.isEmpty)
    }

    @Test func connectionsWhileAskingShareOneQuestion() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        admission.ask = { _ in
            asked += 1
            await Task.yield()
            return true
        }
        async let first = admission.decide(Self.phone)
        async let second = admission.decide(Self.phone)
        let results = await [first, second]
        #expect(results == [true, true])
        #expect(asked == 1)
    }

    /// The list is the iPhone host's paired-devices file, 0600, read again at the next launch.
    @Test func theListSurvivesARelaunchInAPrivateFile() async throws {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.ask = { _ in true }
        #expect(await admission.decide(Self.phone))
        let file = MobileHostPairedDevicesFile(directory: directory).file
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let store = MobileHostPairedStore()
        store.attach(directory: directory)
        let relaunched = PhoneAdmission(phones: store) { _ in }
        store.load(userID: "user-1")
        relaunched.ask = { _ in Issue.record("asked an allowed phone"); return false }
        #expect(await relaunched.decide(Self.phone))
        #expect(Self.listed(relaunched) == ["dev-1"])
    }

    /// Another user signing in starts with no allowed phones; signing out lets no phone in.
    @Test func theListBelongsToTheSignedInUser() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.ask = { _ in true }
        #expect(await admission.decide(Self.phone))
        admission.phones.load(userID: "user-2")
        #expect(Self.listed(admission).isEmpty)
        admission.ask = { _ in false }
        #expect(!(await admission.decide(Self.phone)))
        admission.phones.load(userID: nil)
        admission.mode = .account
        admission.ask = { _ in true }
        #expect(!(await admission.decide(Self.phone)))
        #expect(admission.phones.current == nil)
    }

    /// Escape denies, and Allow has no key: a Return typed as the question opens lets no phone in.
    @Test func theQuestionDeniesOnEscapeAndAllowHasNoKey() {
        let spec = PhoneAccessStrings.allowSpec(name: "Leo’s iPhone", key: String(repeating: "ab", count: 32))
        #expect(spec.identifier == PhoneAdmission.allowDialogIdentifier)
        #expect(spec.defaultButton == nil)
        #expect(spec.buttons.first { $0.role == .cancel }?.id == PhoneAccessStrings.denyID)
    }

    /// The question shows the phone's key next to its name: another device on the account can copy
    /// the name, not the key. Same fingerprint as the phone's Iroh row in Settings > Mobile; a key
    /// that is not hex shows no key line rather than a made-up one.
    @Test func theQuestionShowsTheKeysFingerprint() {
        let key = String(repeating: "ab", count: 32)
        let fingerprint = MobileHostPairedDevices.fingerprint(key)
        #expect(fingerprint.count == 16)
        let other = MobileHostPairedDevices.fingerprint(String(repeating: "cd", count: 32))
        let spec = PhoneAccessStrings.allowSpec(name: "Leo’s iPhone", key: key)
        #expect(spec.lines.first == PhoneAccessStrings.key(key))
        #expect(spec.lines.contains { $0.contains(fingerprint) })
        #expect(!spec.lines.contains { $0.contains(other) })
        #expect(PhoneAccessStrings.allowSpec(name: "Leo’s iPhone", key: "not-hex").lines == [PhoneAccessStrings.message])
    }

    /// An Allow answered after another user signed in counts for nobody: it is not saved on the
    /// new user's list nor on the old one, and lets nothing in.
    @Test func anAllowAnsweredAfterAUserSwitchIsRefusedAndNotSaved() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.ask = { _ in
            admission.phones.load(userID: "user-2")
            return true
        }
        #expect(!(await admission.decide(Self.phone)))
        #expect(Self.listed(admission).isEmpty)
        admission.phones.load(userID: "user-1")
        #expect(Self.listed(admission).isEmpty)
    }

    /// A phone that reconnects as another user while the first user's question is still open does
    /// not join it: the Allow counts for nobody, and neither list gets the phone.
    @Test func aQuestionOpenAcrossAUserSwitchAdmitsNobody() async {
        let (admission, directory, _) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        var release: CheckedContinuation<Void, Never>?
        admission.ask = { _ in
            asked += 1
            await withCheckedContinuation { release = $0 }
            return true
        }
        let first = Task { await admission.decide(Self.phone) }
        while release == nil { await Task.yield() }
        admission.phones.load(userID: "user-2")
        let second = Task { await admission.decide(Self.phone) }
        #expect(!(await second.value))
        release?.resume()
        #expect(!(await first.value))
        #expect(asked == 1)
        #expect(Self.listed(admission).isEmpty)
        admission.phones.load(userID: "user-1")
        #expect(Self.listed(admission).isEmpty)
    }

    /// Waits for the admission's observer to have handled every change made so far: removing an
    /// Iroh entry closes its sessions on the same main-actor hop.
    private static func settle(_ admission: PhoneAdmission, _ closed: Closed, marker: String) async throws {
        let entry = phone(marker, "Marker")
        try admission.phones.change { $0.approve(entry, at: Date()) }
        try admission.phones.change { $0.remove(marker) }
        while await !closed.ids.contains(marker) { await Task.yield() }
    }

    /// Created once the list is already loaded (the app follows the account first): another change
    /// to the same user's list keeps a fresh Deny hold.
    @Test func aSameUserListChangeKeepsTheDenyHold() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-admission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostPairedStore()
        store.attach(directory: directory)
        store.load(userID: "user-1")
        let closed = Closed()
        let admission = PhoneAdmission(phones: store) { await closed.add($0) }
        var asked = 0
        admission.ask = { _ in asked += 1; return false }
        #expect(!(await admission.decide(Self.phone)))
        try await Self.settle(admission, closed, marker: "marker-1")
        #expect(!(await admission.decide(Self.phone)))
        #expect(asked == 1)
    }

    /// Another user's list starts with no Deny holds.
    @Test func aUserChangeDropsTheDenyHolds() async throws {
        let (admission, directory, closed) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        admission.ask = { _ in asked += 1; return false }
        #expect(!(await admission.decide(Self.phone)))
        admission.phones.load(userID: "user-2")
        try await Self.settle(admission, closed, marker: "marker-2")
        #expect(!(await admission.decide(Self.phone)))
        #expect(asked == 2)
    }

    /// Only the iPhone host's account sets whose list it is: the Iroh listener stopping (a team that
    /// went away while signed in, or a sign-out the cloud auth saw first) leaves the one list alone.
    @Test func theIrohListenerNeverSetsTheListsUser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostPairedStore()
        store.attach(directory: directory)
        store.load(userID: "user-1")
        try store.change { $0.approve(Self.phone, at: Date()) }
        let mobile = MobileHostService(displayName: { "Mac" })
        mobile.admit(from: store)
        mobile.stop()
        #expect(store.current?.userID == "user-1")
        #expect(store.current?.devices.map(\.id) == ["dev-1"])
        #expect(await mobile.access.admits(Self.phone))
    }
}
