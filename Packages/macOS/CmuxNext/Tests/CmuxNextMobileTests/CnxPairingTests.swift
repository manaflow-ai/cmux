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
