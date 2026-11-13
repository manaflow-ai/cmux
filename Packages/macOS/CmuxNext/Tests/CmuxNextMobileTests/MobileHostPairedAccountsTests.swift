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

    /// A list an older build saved (one account's list, sealed) is that account's list.
    @Test func anOlderBuildsListIsItsAccounts() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var old = MobileHostPairedDevices(userID: "user-a")
        old.approve(MobileHostPairingTests.request, at: Date(timeIntervalSince1970: 5))
        let data = try JSONEncoder().encode(old)
        let url = directory.appendingPathComponent(MobileHostPairedDevicesFile.fileName)
        try data.write(to: url)
        let seal = MobileHostMemoryPairingSeal()
        #expect(seal.setDigest(MobileHostPairingSeal.digest(data)))
        let file = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        #expect(file.load(userID: "user-a") == old)
        #expect(file.load(userID: "user-b").devices.isEmpty)
        // B's first save moves the file to the per-account form and keeps A's list.
        var b = file.load(userID: "user-b")
        b.approve(MobileHostPairingTests.other, at: Date(timeIntervalSince1970: 6))
        try file.save(b)
        #expect(file.load(userID: "user-a") == old)
        #expect(MobileHostPairedDevicesFile.storedUserIDs(in: try Data(contentsOf: url)) == ["user-a", "user-b"])
    }

    /// A file that does not match its seal trusts nobody: a save for B does not carry A's
    /// (unverified) list forward under a new seal.
    @Test func aTamperedFileKeepsNoOtherAccountsList() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let file = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        var a = file.load(userID: "user-a")
        a.approve(MobileHostPairingTests.request, at: Date(timeIntervalSince1970: 5))
        try file.save(a)
        let text = try String(contentsOf: file.file, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "\"pairedAt\"", with: "\"pairedAt\" ").utf8).write(to: file.file)
        let relaunched = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        var b = relaunched.load(userID: "user-b")
        b.approve(MobileHostPairingTests.other, at: Date(timeIntervalSince1970: 6))
        try relaunched.save(b)
        #expect(relaunched.load(userID: "user-a").devices.isEmpty)
        #expect(relaunched.load(userID: "user-b") == b)
    }

    /// Picking which account an older build's device id belonged to reads either form.
    @Test func storedUserIDsReadsBothForms() throws {
        #expect(MobileHostPairedDevicesFile.storedUserIDs(in: Data(#"{"userID":"a","devices":[],"denied":[]}"#.utf8)) == ["a"])
        #expect(MobileHostPairedDevicesFile.storedUserIDs(in: Data(#"{"accounts":[{"userID":"a","devices":[],"denied":[]},{"userID":"b","devices":[],"denied":[]}]}"#.utf8)) == ["a", "b"])
        #expect(MobileHostPairedDevicesFile.storedUserIDs(in: Data("junk".utf8)) == nil)
    }
}
