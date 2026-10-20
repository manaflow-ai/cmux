import Foundation
import Testing
@testable import CmuxNextMobile

/// Phone pairing on the Mac (cnx-ios verify/phone-approvals.md): hostd's
/// pairing events, the approved list and what hostd and acpmux get from it.
@Suite struct CnxPairingTests {
    static let identity = "04" + String(repeating: "aa", count: 64)
    static let approval = "04" + String(repeating: "bb", count: 64)
    static let request = CnxPairRequest(phoneDeviceID: "p1", name: "Aziz's iPhone", identityKey: identity, approvalKey: approval)

    @Test func parsesPairingEvents() {
        let line = #"{"type":"pair_request","phone_device_id":"p1","name":"Aziz's iPhone","identity_key":"\#(Self.identity)","approval_key":"\#(Self.approval)"}"#
        #expect(CnxHostEvent(line: line) == .pairRequest(Self.request))
        #expect(CnxHostEvent(line: #"{"type":"unpaired","phone_device_id":"p1"}"#) == .unpaired(phoneDeviceID: "p1"))
        #expect(CnxHostEvent(line: #"{"type":"pair_request","phone_device_id":"p1"}"#) == nil)
    }

    @Test func readsTheRegistrationDate() {
        let line = #"{"type":"pair_request","phone_device_id":"p1","name":"Aziz's iPhone","identity_key":"\#(Self.identity)","approval_key":"\#(Self.approval)","registered_at_ms":1800000000500}"#
        guard case .pairRequest(let request)? = CnxHostEvent(line: line) else {
            Issue.record("not a pair request")
            return
        }
        #expect(request.registeredAt == Date(timeIntervalSince1970: 1_800_000_000.5))
        #expect(request.sameKeys(as: Self.request))
    }

    /// Anti-flood (audit M4): one waiting request per phone, a few phones at most, and a quiet
    /// period after Don't Allow in which new requests are only counted.
    @Test func promptsCollapseRepeatsAndQuietAfterADeny() {
        var prompts = CnxPairPrompts()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(prompts.receive(Self.request, at: start) == .ask)
        #expect(prompts.receive(Self.request, at: start) == .repeated)
        // New keys from the waiting phone replace its request, without a new prompt.
        var rotated = Self.request
        rotated.approvalKey = "04" + String(repeating: "dd", count: 64)
        #expect(prompts.receive(rotated, at: start) == .repeated)
        #expect(prompts.pending == [rotated])
        for index in 2...CnxPairPrompts.limit {
            #expect(prompts.receive(Self.phone("p\(index)"), at: start) == .ask)
        }
        #expect(prompts.receive(Self.phone("flood"), at: start) == .blocked)
        #expect(prompts.pending.count == CnxPairPrompts.limit && prompts.blocked == 1)
        #expect(prompts.answer(id: "p2", allowed: true, at: start)?.phoneDeviceID == "p2")
        #expect(!prompts.isQuiet(at: start))
        #expect(prompts.answer(id: "p1", allowed: false, at: start) == rotated)
        #expect(prompts.answer(id: "p1", allowed: false, at: start) == nil)
        #expect(prompts.isQuiet(at: start.addingTimeInterval(CnxPairPrompts.quietPeriod - 1)))
        #expect(prompts.receive(Self.phone("new"), at: start.addingTimeInterval(60)) == .blocked)
        #expect(prompts.blocked == 2)
        // Still waiting requests stay answerable; the quiet period ends on its own.
        #expect(prompts.request(id: "p3") != nil)
        let later = start.addingTimeInterval(CnxPairPrompts.quietPeriod)
        #expect(!prompts.isQuiet(at: later))
        #expect(prompts.receive(Self.phone("new"), at: later) == .ask)
        prompts.forget(id: "new")
        #expect(prompts.request(id: "new") == nil)
    }

    @Test func keysAreHex() {
        #expect(CnxPairedDevices.bytes(hex: "0aFF") == Data([0x0A, 0xFF]))
        #expect(CnxPairedDevices.bytes(hex: "abc") == nil)
        #expect(CnxPairedDevices.bytes(hex: "zz") == nil)
        #expect(CnxPairedDevices.fingerprint("00") == "6e340b9cffb37a98")
    }

    static func phone(_ id: String) -> CnxPairRequest {
        CnxPairRequest(phoneDeviceID: id, name: id, identityKey: identity, approvalKey: approval)
    }

    @Test func decisionsNeedTheSameKeys() {
        var devices = CnxPairedDevices(userID: "u")
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

    @Test func hostdAndAcpmuxGetOnlyApprovedKeys() throws {
        var devices = CnxPairedDevices(userID: "u")
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        devices.deny(CnxPairRequest(phoneDeviceID: "p2", name: "", identityKey: Self.identity, approvalKey: Self.approval))
        let line = CnxHostLaunch.devicesLine(devices)
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
        let file = CnxPairedDevicesFile(directory: directory)
        var devices = file.load(userID: "u")
        devices.approve(Self.request, at: Date(timeIntervalSince1970: 5))
        try file.save(devices)
        #expect(file.load(userID: "u") == devices)
        #expect(file.load(userID: "other").devices.isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: file.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}

/// The Mac's identity key (cnx-ios PROTOCOL.md "Mac identity"): kept across
/// launches, and handed to hostd on one stdin line.
@Suite struct CnxMacIdentityTests {
    @Test func theKeyPersistsAndItsLineCarriesBothHalves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CnxMacIdentityStore(bundleID: "test.bundle", stateDirectory: directory, useKeychain: false)
        let first = try store.loadOrCreate()
        #expect(first.privateKey.count == 32 && first.publicKey.count == 65 && first.publicKey.first == 4)
        #expect(try store.loadOrCreate() == first)
        let mode = try FileManager.default.attributesOfItem(atPath: store.fallbackFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let line = CnxHostLaunch.macIdentityLine(first)
        #expect(line.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: String])
        #expect(object["type"] == "mac_identity")
        #expect(object["private_key"]?.count == 64)
        #expect(object["public_key"]?.hasPrefix("04") == true && object["public_key"]?.count == 130)
        #expect(CnxMacIdentity.restore(first.privateKey) == first)
        #expect(CnxMacIdentity.restore(Data([1, 2])) == nil)
        #expect(first.fingerprint.count == 16)
    }
}
