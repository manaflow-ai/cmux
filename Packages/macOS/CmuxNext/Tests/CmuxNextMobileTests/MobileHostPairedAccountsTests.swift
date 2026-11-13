import Foundation
import Testing
@testable import CmuxNextMobile

/// The phones this Mac allowed are kept per account (Aziz, 2026-11-12: "Approvals on B shouldn't
/// have anything to do with account A"): signing in as B never touches A's list, and A finds its
/// phones again after signing back in.
@Suite struct MobileHostPairedAccountsTests {
    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-paired-accounts-\(UUID().uuidString)")
    }

    @Test func eachAccountKeepsItsOwnList() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let file = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        var a = file.load(userID: "user-a")
        a.approve(MobileHostPairingTests.request, at: Date(timeIntervalSince1970: 5))
        try file.save(a)
        var b = file.load(userID: "user-b")
        #expect(b.devices.isEmpty, "B starts with none of A's phones")
        b.approve(MobileHostPairingTests.other, at: Date(timeIntervalSince1970: 6))
        try file.save(b)
        #expect(file.load(userID: "user-a") == a, "B's save kept A's list")
        #expect(file.load(userID: "user-b") == b)
        // The next launch reads both.
        let relaunched = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        #expect(relaunched.load(userID: "user-a").devices.map(\.id) == ["p1"])
        #expect(relaunched.load(userID: "user-b").devices.map(\.id) == ["p2"])
    }

    /// B's own sign-out forgets B's phones (`forgetForSignOut` saves an empty list): A's stay.
    @Test func oneAccountsSignOutKeepsTheOthers() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = MobileHostPairedDevicesFile(directory: directory, seal: MobileHostMemoryPairingSeal())
        var a = file.load(userID: "user-a")
        a.approve(MobileHostPairingTests.request, at: Date(timeIntervalSince1970: 5))
        try file.save(a)
        var b = file.load(userID: "user-b")
        b.approve(MobileHostPairingTests.other, at: Date(timeIntervalSince1970: 6))
        try file.save(b)
        try file.save(MobileHostPairedDevices(userID: "user-b"))
        #expect(file.load(userID: "user-b").devices.isEmpty)
        #expect(file.load(userID: "user-a") == a)
    }
}
