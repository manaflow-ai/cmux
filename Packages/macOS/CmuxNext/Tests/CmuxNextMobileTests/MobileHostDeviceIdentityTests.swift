import Foundation
import Testing
@testable import CmuxNextMobile

/// This Mac's mobile device id is per account (Aziz, 2026-11-12: "A's ID should be completely
/// different from B's ID ... We must keep the Mac's ID and approved phones per account"), and a
/// state folder copied to another Mac (Migration Assistant, a restore) makes a new id there.
@Suite struct MobileHostDeviceIdentityTests {
    let thisMac = Data(repeating: 7, count: 16)
    let otherMac = Data(repeating: 9, count: 16)

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-mobile-identity-\(UUID().uuidString)")
    }

    func identity(_ directory: URL, _ owner: String, mac: Data? = Data(repeating: 7, count: 16)) -> MobileHostDeviceIdentity {
        MobileHostDeviceIdentity(directory: directory, owner: owner, hostUUID: { mac })
    }

    /// The report: A signs out, B signs in on the same build. B must not register A's id (the
    /// service answers `not_owner` and B's phones never find this Mac).
    @Test func twoAccountsOnOneBuildGetDifferentIDs() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try identity(directory, "user-a").deviceID()
        let b = try identity(directory, "user-b").deviceID()
        #expect(a != b)
        // Back to A: A's id again, and B's stays B's.
        #expect(try identity(directory, "user-a").deviceID() == a)
        #expect(try identity(directory, "user-b").deviceID() == b)
    }

    @Test func forgettingOneAccountsIDKeepsTheOthers() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try identity(directory, "user-a").deviceID()
        let b = try identity(directory, "user-b").deviceID()
        identity(directory, "user-a").forget()
        #expect(try identity(directory, "user-a").deviceID() != a)
        #expect(try identity(directory, "user-b").deviceID() == b)
    }

    /// A refusal names the id it was about: an id this account made since (a renewal already ran)
    /// is not forgotten for it.
    @Test func forgettingARefusedIDForgetsOnlyThatID() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = try identity(directory, "user-a").deviceID()
        #expect(!identity(directory, "user-a").forget(ifID: "00000000-0000-4000-8000-000000000000"))
        #expect(try identity(directory, "user-a").deviceID() == current)
        #expect(identity(directory, "user-a").forget(ifID: current.uppercased()))
        #expect(try identity(directory, "user-a").deviceID() != current)
    }

    /// A machine stamp that cannot be written keeps the id (the check runs again later).
    @Test func anUnwritableMachineStampKeepsTheID() throws {
        let directory = folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let id = try identity(directory, "user-a").deviceID()
        try FileManager.default.removeItem(at: identity(directory, "user-a").machineFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        #expect(try identity(directory, "user-a").deviceID() == id)
    }

    /// Migration Assistant copied the folder to a new Mac: the id made on the old Mac is not
    /// this Mac's, so this Mac registers as a new device (the old Mac keeps its own).
    @Test func aFolderCopiedFromAnotherMacMakesANewID() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try identity(directory, "user-a", mac: otherMac).deviceID()
        let copied = try identity(directory, "user-a", mac: thisMac).deviceID()
        #expect(copied != old)
        // Stable on this Mac from now on.
        #expect(try identity(directory, "user-a", mac: thisMac).deviceID() == copied)
    }

    /// A record from before the machine check (no machine file) is kept and stamped with this Mac.
    @Test func aRecordWithoutAMachineIsKept() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try identity(directory, "user-a").deviceID()
        try FileManager.default.removeItem(at: identity(directory, "user-a").machineFile)
        #expect(try identity(directory, "user-a").deviceID() == id)
        #expect(FileManager.default.fileExists(atPath: identity(directory, "user-a").machineFile.path))
    }

    /// No host UUID (a sandbox that refuses it): the id is kept, never churned.
    @Test func noHostUUIDKeepsTheID() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try identity(directory, "user-a").deviceID()
        #expect(try identity(directory, "user-a", mac: nil).deviceID() == id)
    }

    /// An older build's one `device-id` belongs to the account its paired list names: that
    /// account adopts it (its phones keep this Mac); another account gets its own.
    @Test func theAccountAnOlderBuildRanForAdoptsItsID() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = "6f1c1a1e-0000-4000-8000-000000000001"
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("device-id"))
        try Data(#"{"userID":"user-a","devices":[],"denied":[]}"#.utf8)
            .write(to: directory.appendingPathComponent(MobileHostPairedDevicesFile.fileName))
        #expect(try identity(directory, "user-b").deviceID() != legacy)
        #expect(try identity(directory, "user-a").deviceID() == legacy)
        // Moved, not copied: nobody else adopts it later.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("device-id").path))
    }

    /// No paired list (no phone ever pinned this Mac): the first account takes the old id; if it
    /// was another account's, the service refuses it and the iPhone host renews it.
    @Test func withoutAPairedListTheFirstAccountAdoptsTheOldID() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = "6f1c1a1e-0000-4000-8000-000000000002"
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("device-id"))
        #expect(try identity(directory, "user-a").deviceID() == legacy)
        #expect(try identity(directory, "user-b").deviceID() != legacy)
    }

    /// The tag matches the machine id hostd registers (cmux-mobile-host `config::machine_id`, same vector).
    @Test func theMachineTagMatchesHostd() {
        let uuid = Data((0..<16).map { UInt8($0) })
        #expect(MobileHostDeviceIdentity.machineTag(owner: "owner-a", hostUUID: uuid) == "932b2e0a89479d962ad858b73cf4db9a")
        #expect(MobileHostDeviceIdentity.machineTag(owner: "owner-b", hostUUID: uuid) != "932b2e0a89479d962ad858b73cf4db9a")
    }

    /// An owner that is not a plain id never names a path.
    @Test func anUnusualOwnerIsHashed() {
        #expect(MobileHostDeviceIdentity.component(of: "9a7c1f0e-1b2c-4d3e-8f90-123456789abc") == "9a7c1f0e-1b2c-4d3e-8f90-123456789abc")
        #expect(MobileHostDeviceIdentity.component(of: "../x").count == 64)
        #expect(MobileHostDeviceIdentity.component(of: "").count == 64)
    }

    @Test func theRegisteredNameCarriesTheLane() {
        #expect(MobileHostDeviceName(computer: "Aziz's MacBook Pro", label: nil).value == "Aziz's MacBook Pro")
        #expect(MobileHostDeviceName(computer: "Aziz's MacBook Pro", label: "NIGHTLY").value == "Aziz's MacBook Pro (NIGHTLY)")
        #expect(MobileHostDeviceName(computer: "Mini", label: "DEV my-tag").value == "Mini (DEV my-tag)")
        #expect(MobileHostDeviceName(computer: "Mini", label: " ").value == "Mini")
    }
}
