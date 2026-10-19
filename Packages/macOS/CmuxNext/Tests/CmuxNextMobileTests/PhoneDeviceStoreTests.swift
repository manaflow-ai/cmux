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
        try PhoneDeviceStore(directory: directory).allow(PhoneDevice(id: "a", name: "iPhone", approvedAt: approved))
        let reopened = PhoneDeviceStore(directory: directory)
        #expect(reopened.all.map(\.id) == ["a"])
        #expect(reopened.all.first?.approvedAt == approved)
        let file = directory.appendingPathComponent("phone-access/devices.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(folder == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers == ["devices.json"])
    }

    /// A Remove that cannot be written throws and keeps the phone listed (and so allowed).
    @Test func aFailedRemoveKeepsThePhone() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhoneDeviceStore(directory: directory)
        try store.allow(PhoneDevice(id: "a", name: "A"))
        // A non-empty folder where the list goes: the rename over it fails.
        let file = directory.appendingPathComponent("phone-access/devices.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.appendingPathComponent("blocker"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.remove("a") }
        #expect(store.contains("a"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftovers == ["devices.json"])
    }

    @Test func aRenamedPhoneKeepsItsApproval() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhoneDeviceStore(directory: directory)
        let approved = Date(timeIntervalSince1970: 1_800_000_000)
        try store.allow(PhoneDevice(id: "a", name: "iPhone", approvedAt: approved))
        try store.allow(PhoneDevice(id: "a", name: "Leo's iPhone"))
        #expect(store.all.count == 1)
        #expect(store.all.first?.name == "Leo's iPhone")
        #expect(store.all.first?.approvedAt == approved)
    }

    @Test func removeAndTouch() throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PhoneDeviceStore(directory: directory)
        try store.allow(PhoneDevice(id: "a", name: "A"))
        try store.allow(PhoneDevice(id: "b", name: "B"))
        let seen = Date(timeIntervalSince1970: 1_900_000_000)
        try store.touch("b", at: seen)
        try store.remove("a")
        #expect(store.all.map(\.id) == ["b"])
        #expect(store.all.first?.lastSeenAt == seen)
        #expect(!store.contains("a"))
    }

    @Test func theGateAdmitsUntilARuleIsSet() async {
        let gate = PhoneAccessGate()
        let phone = PhoneDevice(id: "a", name: "A")
        #expect(await gate.admits(phone))
        #expect(gate.stillAllows("a"))
        gate.setAdmission({ _ in false }, stillAllowed: { $0 == "b" })
        #expect(!(await gate.admits(phone)))
        #expect(!gate.stillAllows("a"))
        #expect(gate.stillAllows("b"))
    }
}
