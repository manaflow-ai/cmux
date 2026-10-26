import Foundation
import Security
import Testing
@testable import CmuxNextMobile

/// Phone pairing on the Mac (cmux-next-ios verify/phone-approvals.md): hostd's
/// pairing events, the approved list and what hostd and acpmux get from it.
@Suite struct MobileHostPairingTests {
    static let identity = "04" + String(repeating: "aa", count: 64)
    static let approval = "04" + String(repeating: "bb", count: 64)
    static let request = MobileHostPairRequest(phoneDeviceID: "p1", name: "Aziz's iPhone", identityKey: identity, approvalKey: approval)

    @Test func parsesPairingEvents() {
        let line = #"{"type":"pair_request","phone_device_id":"p1","name":"Aziz's iPhone","identity_key":"\#(Self.identity)","approval_key":"\#(Self.approval)"}"#
        #expect(MobileHostEvent(line: line) == .pairRequest(Self.request))
        #expect(MobileHostEvent(line: #"{"type":"unpaired","phone_device_id":"p1"}"#) == .unpaired(phoneDeviceID: "p1"))
        #expect(MobileHostEvent(line: #"{"type":"pair_request","phone_device_id":"p1"}"#) == nil)
    }

    @Test func readsTheRegistrationDate() {
        let line = #"{"type":"pair_request","phone_device_id":"p1","name":"Aziz's iPhone","identity_key":"\#(Self.identity)","approval_key":"\#(Self.approval)","registered_at_ms":1800000000500}"#
        guard case .pairRequest(let request)? = MobileHostEvent(line: line) else {
            Issue.record("not a pair request")
            return
        }
        #expect(request.registeredAt == Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(request.sameKeys(as: Self.request))
    }

    /// Anti-flood (audit M4): one waiting request per phone, a few phones at most, and a quiet
    /// period after Don't Allow in which new requests are only counted.
    @Test func promptsCollapseRepeatsAndQuietAfterADeny() {
        var prompts = MobileHostPairPrompts()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(prompts.receive(Self.request, at: start) == .ask)
        #expect(prompts.receive(Self.request, at: start) == .repeated)
        // New keys from the waiting phone replace its request, without a new prompt.
        var rotated = Self.request
        rotated.approvalKey = "04" + String(repeating: "dd", count: 64)
        #expect(prompts.receive(rotated, at: start) == .repeated)
        #expect(prompts.pending == [rotated])
        for index in 2...MobileHostPairPrompts.limit {
            #expect(prompts.receive(Self.phone("p\(index)"), at: start) == .ask)
        }
        #expect(prompts.receive(Self.phone("flood"), at: start) == .blocked)
        #expect(prompts.pending.count == MobileHostPairPrompts.limit && prompts.blocked == 1)
        #expect(prompts.answer(id: "p2", allowed: true, at: start)?.phoneDeviceID == "p2")
        #expect(!prompts.isQuiet(at: start))
        #expect(prompts.answer(id: "p1", allowed: false, at: start) == rotated)
        #expect(prompts.answer(id: "p1", allowed: false, at: start) == nil)
        #expect(prompts.isQuiet(at: start.addingTimeInterval(MobileHostPairPrompts.quietPeriod - 1)))
        #expect(prompts.receive(Self.phone("new"), at: start.addingTimeInterval(60)) == .blocked)
        #expect(prompts.blocked == 2)
        // Still waiting requests stay answerable; the quiet period ends on its own.
        #expect(prompts.request(id: "p3") != nil)
        let later = start.addingTimeInterval(MobileHostPairPrompts.quietPeriod)
        #expect(!prompts.isQuiet(at: later))
        #expect(prompts.receive(Self.phone("new"), at: later) == .ask)
        prompts.forget(id: "new")
        #expect(prompts.request(id: "new") == nil)
    }

    @Test func keysAreHex() {
        #expect(MobileHostPairedDevices.bytes(hex: "0aFF") == Data([0x0A, 0xFF]))
        #expect(MobileHostPairedDevices.bytes(hex: "abc") == nil)
        #expect(MobileHostPairedDevices.bytes(hex: "zz") == nil)
        #expect(MobileHostPairedDevices.fingerprint("00") == "6e340b9cffb37a98")
    }

    static func phone(_ id: String) -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: id, name: id, identityKey: identity, approvalKey: approval)
    }

    @Test func decisionsNeedTheSameKeys() {
        var devices = MobileHostPairedDevices(userID: "u")
        #expect(devices.decision(for: Self.request) == .ask)
        devices.deny(Self.request)
        #expect(devices.decision(for: Self.request) == .denied)
        // A new identity key (the phone signed out and in) asks again.
        var fresh = Self.request
        fresh.identityKey = "04" + String(repeating: "cc", count: 64)
        #expect(devices.decision(for: fresh) == .ask)
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        #expect(devices.decision(for: Self.request) == .trusted)
        #expect(devices.denied.isEmpty)
        // A new approval key under the same identity asks again.
        var rotated = Self.request
        rotated.approvalKey = "04" + String(repeating: "dd", count: 64)
        #expect(devices.decision(for: rotated) == .ask)
        devices.approve(rotated, at: Date(timeIntervalSince1970: 6))
        #expect(devices.devices.count == 1 && devices.devices[0].approvalKey == rotated.approvalKey)
        devices.remove("p1")
        #expect(devices.devices.isEmpty && devices.decision(for: rotated) == .ask)
    }

    /// A phone's row and its acpmux credential follow its link id (the id it paired with), even
    /// when its presence id sorts first; a paired phone the account no longer lists (removed while
    /// this Mac was not running) gets no credential, so it never holds Full access.
    @Test func aPairedPhoneIsItsLinkIDAndOnlyAListedOneGetsACredential() {
        let link = "B0000000-0000-4000-8000-000000000001"
        let presence = "A0000000-0000-4000-8000-000000000002"
        var devices = MobileHostPairedDevices(userID: "u")
        devices.approve(Self.phone(link), at: Date(timeIntervalSince1970: 5))
        devices.approve(Self.phone("gone"), at: Date(timeIntervalSince1970: 6))
        let phone = MobileHostKnownPhone(name: "Leo's iPhone", deviceIDs: [link, presence], updatedAt: nil)
        #expect(phone.id == presence, "the presence id sorts first")
        #expect(devices.pairing(of: phone)?.id == link)
        #expect(devices.listed(in: [phone]) == [link])
        #expect(devices.listed(in: []).isEmpty, "a phone the account does not list gets no credential")
        #expect(devices.pairing(of: MobileHostKnownPhone(name: "Other", deviceIDs: ["other"], updatedAt: nil)) == nil)
    }

    @Test func hostdAndAcpmuxGetOnlyApprovedKeys() throws {
        var devices = MobileHostPairedDevices(userID: "u")
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        devices.deny(MobileHostPairRequest(phoneDeviceID: "p2", name: "", identityKey: Self.identity, approvalKey: Self.approval))
        let line = MobileHostLaunch.devicesLine(devices)
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(object["type"] as? String == "devices")
        #expect(object["denied"] as? [[String: String]] == [["id": "p2", "identity_key": Self.identity]])
        let listed = try #require(object["devices"] as? [[String: String]])
        #expect(listed == [["id": "p1", "identity_key": Self.identity, "approval_key": Self.approval]])
        let params = devices.approversParams(macDevice: "mac-1")
        #expect(params["macDevice"] as? String == "mac-1")
        #expect((params["approvers"] as? [[String: String]]) == [["id": "p1", "publicKey": Self.approval, "name": "Aziz's iPhone"]])
        #expect(devices.devices[0].fingerprint.count == 16)
    }

    @Test func theFileBelongsToOneUser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = MobileHostPairedDevicesFile(directory: directory, seal: MobileHostMemoryPairingSeal())
        var devices = file.load(userID: "u")
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        try file.save(devices)
        #expect(file.load(userID: "u") == devices)
        #expect(file.load(userID: "other").devices.isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: file.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    static let other = MobileHostPairRequest(phoneDeviceID: "p2", name: "Other iPhone",
                                             identityKey: "04" + String(repeating: "dd", count: 64),
                                             approvalKey: "04" + String(repeating: "ee", count: 64))

    /// The paired list as the app reads it at its next launch (a new file object, the same seal),
    /// and what reaches acpmux (approvers) and hostd (pinned keys) from it.
    static func relaunched(_ directory: URL, seal: any MobileHostPairingSealStore) -> (approvers: [[String: String]], hostd: [[String: String]]) {
        let list = MobileHostPairedDevicesFile(directory: directory, seal: seal).load(userID: "u")
        let approvers = list.approversParams(macDevice: "mac-1")["approvers"] as? [[String: String]] ?? []
        let line = (try? JSONSerialization.jsonObject(with: MobileHostLaunch.devicesLine(list))) as? [String: Any]
        return (approvers, line?["devices"] as? [[String: String]] ?? [])
    }

    /// A list with one approved phone, saved under `seal`.
    static func saved(_ directory: URL, seal: any MobileHostPairingSealStore) throws -> (MobileHostPairedDevicesFile, MobileHostPairedDevices) {
        let file = MobileHostPairedDevicesFile(directory: directory, seal: seal)
        var devices = file.load(userID: "u")
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        try file.save(devices)
        return (file, devices)
    }

    /// A same-user process rewrites paired-devices.json, swapping in a key of its own: at the next
    /// launch no approver is enrolled and hostd pins nothing (#24233, landing term 5).
    @Test func aTamperedListEnrollsNoApproverAfterARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let (file, _) = try Self.saved(directory, seal: seal)
        #expect(Self.relaunched(directory, seal: seal).approvers.map { $0["publicKey"] } == [Self.approval])

        let theirs = "04" + String(repeating: "cc", count: 64)
        let text = try String(contentsOf: file.file, encoding: .utf8).replacingOccurrences(of: Self.approval, with: theirs)
        try Data(text.utf8).write(to: file.file)
        let relaunched = Self.relaunched(directory, seal: seal)
        #expect(relaunched.approvers.isEmpty, "a tampered list enrolled \(relaunched.approvers)")
        #expect(relaunched.hostd.isEmpty, "hostd pinned \(relaunched.hostd)")
    }

    /// A same-user process keeps a copy of the list, waits for the person to remove the phone, then
    /// puts the copy back: the removed phone is not trusted again.
    @Test func anOlderListPutBackTrustsNoPhone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let (file, saved) = try Self.saved(directory, seal: seal)
        var devices = saved
        let copy = try Data(contentsOf: file.file)
        devices.remove(Self.request.phoneDeviceID)
        try file.save(devices)
        try copy.write(to: file.file)
        let relaunched = Self.relaunched(directory, seal: seal)
        #expect(relaunched.approvers.isEmpty, "the removed phone came back as an approver: \(relaunched.approvers)")
        #expect(relaunched.hostd.isEmpty, "hostd pinned the removed phone: \(relaunched.hostd)")
    }

    /// A list with no digest (one an older build wrote) or a Keychain that refuses trusts no phone;
    /// a save the Keychain refuses throws and leaves the list as it was.
    @Test func aListWithoutItsDigestTrustsNoPhone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let (file, saved) = try Self.saved(directory, seal: seal)
        var devices = saved
        #expect(Self.relaunched(directory, seal: MobileHostMemoryPairingSeal()).approvers.isEmpty, "no digest")
        #expect(Self.relaunched(directory, seal: MobileHostMemoryPairingSeal(refuses: true)).approvers.isEmpty, "Keychain refuses")
        devices.approve(Self.other, at: Date(timeIntervalSince1970: 6))
        #expect(throws: MobileHostPairingSealError.keychainRefused) {
            try MobileHostPairedDevicesFile(directory: directory, seal: MobileHostMemoryPairingSeal(refuses: true)).save(devices)
        }
        #expect(Self.relaunched(directory, seal: seal).approvers.count == 1, "a refused save changed the list")
        try file.save(devices)
        #expect(Self.relaunched(directory, seal: seal).approvers.count == 2)
    }

    /// The person removes a phone and the new list's digest is never recorded (a crash between
    /// the file and its digest, or a Keychain that refuses it): an older copy put back then still
    /// trusts no phone, because the old digest went first.
    @Test func aRevocationWhoseDigestIsNotRecordedLeavesNoOlderListTrusted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let (file, saved) = try Self.saved(directory, seal: seal)
        var devices = saved
        let copy = try Data(contentsOf: file.file)
        seal.refuseRecords()
        devices.remove(Self.request.phoneDeviceID)
        try file.save(devices)
        try copy.write(to: file.file)
        let relaunched = Self.relaunched(directory, seal: seal)
        #expect(relaunched.approvers.isEmpty, "the removed phone came back as an approver: \(relaunched.approvers)")
        #expect(relaunched.hostd.isEmpty, "hostd pinned the removed phone: \(relaunched.hostd)")
    }

    /// The iPhone host reads and writes off the main actor, in order: a read queued after a save
    /// sees it.
    @Test func aBackgroundReadSeesTheSavesQueuedBeforeIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = MobileHostPairedDevicesFile(directory: directory, seal: MobileHostMemoryPairingSeal())
        var devices = MobileHostPairedDevices(userID: "u")
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        file.saveInBackground(devices)
        devices.approve(Self.other, at: Date(timeIntervalSince1970: 6))
        file.saveInBackground(devices)
        #expect(await file.loadInBackground(userID: "u") == devices)
    }

    /// The digest lives in the data-protection Keychain, in the app's own access group, never synced.
    @Test func theSealIsInTheAppsOwnDataProtectionKeychain() {
        let seal = MobileHostKeychainPairingSeal(bundleID: "com.cmuxterm.app.next")
        #expect(seal.service == "com.cmuxterm.app.next.iphone-host.pairing-seal")
        let query = MobileHostKeychainPairingSeal.query(service: seal.service)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] == nil, "the app's default (entitled) group, not a named one")
    }
}

/// The Mac's identity key (cmux-next-ios PROTOCOL.md "Mac identity"): kept across
/// launches, and handed to hostd on one stdin line.
@Suite struct MobileHostMacIdentityTests {
    @Test func theKeyPersistsAndItsLineCarriesBothHalves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileHostMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, useKeychain: false)
        let first = try store.loadOrCreate()
        #expect(first.privateKey.count == 32 && first.publicKey.count == 65 && first.publicKey.first == 4)
        #expect(try store.loadOrCreate() == first)
        let mode = try FileManager.default.attributesOfItem(atPath: store.fallbackFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let line = MobileHostLaunch.macIdentityLine(first)
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String])
        #expect(object["type"] == "mac_identity")
        #expect(object["private_key"]?.count == 64)
        #expect(object["public_key"]?.hasPrefix("04") == true && object["public_key"]?.count == 130)
        #expect(MobileHostMacIdentity.restore(first.privateKey) == first)
        #expect(MobileHostMacIdentity.restore(Data([1, 2])) == nil)
        #expect(first.fingerprint.count == 16)
    }
}
