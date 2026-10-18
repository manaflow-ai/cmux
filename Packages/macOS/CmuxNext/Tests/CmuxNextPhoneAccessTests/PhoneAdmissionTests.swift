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
    private static func admission() -> (PhoneAdmission, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-admission-\(UUID().uuidString)")
        return (PhoneAdmission(store: PhoneDeviceStore(directory: directory)), directory)
    }

    private static let phone = PhoneDevice(id: "dev-1", name: "Leo's iPhone")

    @Test func allowListsThePhoneAndAsksOnce() async {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        admission.ask = { _ in asked += 1; return true }
        #expect(await admission.decide(Self.phone))
        #expect(await admission.decide(Self.phone))
        #expect(asked == 1)
        #expect(admission.devices.map(\.id) == ["dev-1"])
        #expect(admission.devices.first?.lastSeenAt != nil)
    }

    @Test func denyHoldsForTenMinutes() async {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        admission.ask = { _ in asked += 1; return false }
        let start = ContinuousClock.now
        #expect(!(await admission.decide(Self.phone, now: start)))
        #expect(!(await admission.decide(Self.phone, now: start + .seconds(60))))
        #expect(asked == 1)
        _ = await admission.decide(Self.phone, now: start + PhoneAdmission.denialHold + .seconds(1))
        #expect(asked == 2)
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

    @Test func removeMakesItAskAgain() async {
        let (admission, directory) = Self.admission()
        defer { try? FileManager.default.removeItem(at: directory) }
        var answers = [true, false]
        admission.ask = { _ in answers.removeFirst() }
        #expect(await admission.decide(Self.phone))
        admission.remove(Self.phone.id)
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
}
