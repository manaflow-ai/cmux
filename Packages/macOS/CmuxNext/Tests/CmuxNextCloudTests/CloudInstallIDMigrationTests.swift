import CmuxNextCloud
import CmuxNextCompat
import Foundation
import Testing

/// A Cloud folder that Migration Assistant or a restore copied to another Mac makes a new install id
/// there (Aziz, 2026-11-19: "make it work as a new device even after migration assistant"), so the new
/// Mac is not a second copy of the old one in its tabs, window records and tunnel.
@Suite
struct CloudInstallIDMigrationTests {
    static let oldMac = HostMachine(uuid: Data(repeating: 1, count: 16))
    static let newMac = HostMachine(uuid: Data(repeating: 2, count: 16))

    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cloud-migration-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aFolderCopiedToAnotherMacMakesANewID() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try CloudPaths(root: root, host: { Self.oldMac }).loadOrCreateDeviceID()
        let new = try CloudPaths(root: root, host: { Self.newMac }).loadOrCreateDeviceID()
        #expect(new != old && new.hasPrefix("mac-"))
        #expect(try CloudPaths(root: root, host: { Self.newMac }).loadOrCreateDeviceID() == new)
    }

    @Test func theSameMacKeepsItsID() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try CloudPaths(root: root, host: { Self.oldMac }).loadOrCreateDeviceID()
        #expect(try CloudPaths(root: root, host: { Self.oldMac }).loadOrCreateDeviceID() == id)
    }

    /// An older build's id (no record of its computer) is kept and stamped; no host UUID keeps it too.
    @Test func anUnstampedIDIsKeptAndStamped() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try CloudPaths(root: root, host: { nil }).loadOrCreateDeviceID()
        #expect(try CloudPaths(root: root, host: { Self.oldMac }).loadOrCreateDeviceID() == id)
        #expect(try CloudPaths(root: root, host: { Self.newMac }).loadOrCreateDeviceID() != id)
    }

    /// First reads at once on the new Mac agree on one new id.
    @Test func concurrentReadsOnTheNewMacAgree() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try CloudPaths(root: root, host: { Self.oldMac }).loadOrCreateDeviceID()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask(priority: .medium) { try CloudPaths(root: root, host: { Self.newMac }).loadOrCreateDeviceID() }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1 && !ids.contains(old))
    }

    @Test func stampsDifferByPurposeAndMachine() {
        #expect(Self.oldMac.stamp(purpose: "a") != Self.newMac.stamp(purpose: "a"))
        #expect(Self.oldMac.stamp(purpose: "a") != Self.oldMac.stamp(purpose: "b"))
        #expect(Self.oldMac.stamp(purpose: "a").count == 32)
    }
}
