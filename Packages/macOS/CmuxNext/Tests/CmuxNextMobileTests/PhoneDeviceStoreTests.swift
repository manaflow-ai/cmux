import Foundation
import Testing
@testable import CmuxNextMobile

/// The allowed phones survive a relaunch (one JSON file), a renamed phone
/// keeps its approval, and Remove takes it off the list. The gate admits
/// every phone until the app sets an admission rule.
struct PhoneDeviceStoreTests {
    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("phone-store-\(UUID().uuidString)")
    }

    @Test func theListSurvivesARelaunch() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let approved = Date(timeIntervalSince1970: 1_800_000_000)
        PhoneDeviceStore(directory: directory).allow(PhoneDevice(id: "a", name: "iPhone", approvedAt: approved))
        let reopened = PhoneDeviceStore(directory: directory)
        #expect(reopened.all.map(\.id) == ["a"])
        #expect(reopened.all.first?.approvedAt == approved)
        let file = directory.appendingPathComponent("phone-access/devices.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aRenamedPhoneKeepsItsApproval() {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhoneDeviceStore(directory: directory)
        let approved = Date(timeIntervalSince1970: 1_800_000_000)
        store.allow(PhoneDevice(id: "a", name: "iPhone", approvedAt: approved))
        store.allow(PhoneDevice(id: "a", name: "Leo's iPhone"))
        #expect(store.all.count == 1)
        #expect(store.all.first?.name == "Leo's iPhone")
        #expect(store.all.first?.approvedAt == approved)
    }

    @Test func removeAndTouch() {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhoneDeviceStore(directory: directory)
        store.allow(PhoneDevice(id: "a", name: "A"))
        store.allow(PhoneDevice(id: "b", name: "B"))
        let seen = Date(timeIntervalSince1970: 1_900_000_000)
        store.touch("b", at: seen)
        store.remove("a")
        #expect(store.all.map(\.id) == ["b"])
        #expect(store.all.first?.lastSeenAt == seen)
        #expect(!store.contains("a"))
    }

    @Test func theGateAdmitsUntilARuleIsSet() async {
        let gate = PhoneAccessGate()
        let phone = PhoneDevice(id: "a", name: "A")
        #expect(await gate.admits(phone))
        gate.setAdmission { _ in false }
        #expect(!(await gate.admits(phone)))
    }
}
