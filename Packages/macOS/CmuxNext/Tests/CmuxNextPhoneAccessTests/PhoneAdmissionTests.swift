@testable import CmuxNextPhoneAccess
import CmuxNextMobile
import Foundation
import Testing

/// `phone.newDevices`: a phone on the allowed list gets in; a new one asks
/// once on this Mac (Allow lists it, Deny holds for ten minutes); Any Phone on
/// My Account lets it in and lists it; Remove makes it ask again.
@Suite(.serialized)
@MainActor
struct PhoneAdmissionTests {
    private static func admission(user: String? = "user-1") -> (PhoneAdmission, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-admission-\(UUID().uuidString)")
        let admission = PhoneAdmission(phones: AllowedPhones(directory: directory))
        admission.setUser(user)
        return (admission, directory)
    }

    private static func phone(_ id: String, _ name: String) -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: id, name: name, identityKey: id, approvalKey: "")
    }

    private static let phone = phone("dev-1", "Leo's iPhone")

    @Test func allowListsThePhoneAndAsksOnce() async {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        admission.ask = { _ in asked += 1; return true }
        #expect(await admission.decide(Self.phone))
        #expect(await admission.decide(Self.phone))
        #expect(asked == 1)
        #expect(admission.devices.map(\.id) == ["dev-1"])
        #expect(admission.lastSeen["dev-1"] != nil)
    }

    @Test func denyHoldsForTenMinutes() async {
        let (admission, directory) = Self.admission()
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
        #expect(admission.devices.isEmpty)
    }

    /// The hold starts when Deny is pressed, not when the question opened.
    @Test func theHoldStartsAtTheAnswer() async {
        let (admission, directory) = Self.admission()
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
        let (admission, directory) = Self.admission()
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
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)  // a file where the folder must go
        admission.ask = { _ in true }
        #expect(!(await admission.decide(Self.phone)))
        #expect(admission.devices.isEmpty)
    }

    @Test func anyPhoneOnTheAccountGetsInAndIsListed() async {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.mode = .account
        admission.ask = { _ in Issue.record("asked in account mode"); return false }
        #expect(await admission.decide(Self.phone))
        #expect(admission.devices.map(\.id) == ["dev-1"])
    }

    @Test func removeMakesItAskAgain() async throws {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var answers = [true, false]
        admission.ask = { _ in answers.removeFirst() }
        #expect(await admission.decide(Self.phone))
        try admission.remove(Self.phone.phoneDeviceID)
        #expect(admission.devices.isEmpty)
        #expect(!(await admission.decide(Self.phone)))
        #expect(answers.isEmpty)
    }

    @Test func connectionsWhileAskingShareOneQuestion() async {
        let (admission, directory) = Self.admission()
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

    /// The list is base's paired-devices file under phone-access, 0600, read again at the next launch.
    @Test func theListSurvivesARelaunchInAPrivateFile() async throws {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.ask = { _ in true }
        #expect(await admission.decide(Self.phone))
        let file = directory.appendingPathComponent("phone-access/paired-devices.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let relaunched = PhoneAdmission(phones: AllowedPhones(directory: directory))
        relaunched.setUser("user-1")
        relaunched.ask = { _ in Issue.record("asked an allowed phone"); return false }
        #expect(await relaunched.decide(Self.phone))
        #expect(relaunched.devices.map(\.id) == ["dev-1"])
    }

    /// Another user signing in starts with no allowed phones; signing out lets no phone in.
    @Test func theListBelongsToTheSignedInUser() async {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        admission.ask = { _ in true }
        #expect(await admission.decide(Self.phone))
        admission.setUser("user-2")
        #expect(admission.devices.isEmpty)
        admission.ask = { _ in false }
        #expect(!(await admission.decide(Self.phone)))
        admission.setUser(nil)
        admission.mode = .account
        admission.ask = { _ in true }
        #expect(!(await admission.decide(Self.phone)))
        #expect(admission.devices.isEmpty)
    }
}
