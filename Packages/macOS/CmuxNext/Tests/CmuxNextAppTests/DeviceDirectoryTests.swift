import CmuxNextMobile
@testable import CmuxNextServer
import Foundation
import Testing

/// Settings > Devices (plans/cmux-next/add-device-DESIGN.md 2.4-2.6): the CLI's listing parses,
/// the directory merges the CLI's devices and the Mac's phones, removes through one path, and reads
/// again after a remove. The Add Device card's own flow is the page's (bun:
/// webviews/src/pages/server-cards/addDevice/model.test.ts, webviews/test/server-cards-add-device.test.tsx).
@MainActor @Suite(.serialized) struct DeviceDirectoryTests {
    @Test func theCLIsListingParses() throws {
        let json = """
        {"network":{"kind":"tailscale","up":true,"this":"lawrence-mbp"},
         "devices":[{"id":"peer:mini-7","name":"mini-7","kind":"computer","roles":["runs-agents"],"state":"connected",
                     "os":"macOS","reach":{"network":"tailscale","address":"mini-7.ts.net","ips":[],"online":true},
                     "via":[{"store":"peer","name":"mini-7"}],"added_at":"2026-10-22T07:12:00Z"}],
         "available":[{"name":"studio","address":"studio.ts.net","os":"macOS","mine":true},
                      {"name":"devbox","address":"devbox","os":"","mine":true,"found":"ssh-config"}],
         "invites":[{"id":"tk_1","role":"client","label":null,"expires_at":"2026-10-22T08:00:00Z"}],
         "notes":[]}
        """
        let listing = try DeviceListing.parse(Data(json.utf8))
        #expect(listing.devices.first?.addedAt == "2026-10-22T07:12:00Z")
        #expect(listing.available.first?.mine == true)
        #expect(listing.available.map(\.fromSSHConfig) == [false, true])
        #expect(listing.invites.map(\.id) == ["tk_1"])
    }

    // MARK: - Settings > Devices

    final class FakeCLI {
        var calls: [[String]] = []
        var removeFails = false
        var listing = """
        {"network":{"kind":"tailscale","up":true},"devices":[
          {"id":"peer:mini-7","name":"mini-7","kind":"computer","roles":["runs-agents"],"state":"connected"},
          {"id":"grant:new@manaflow.ai","name":"new@manaflow.ai","kind":"computer","roles":["uses-this"],"state":"pending",
           "detail":"new@manaflow.ai has not approved this access on their computer yet."}],
         "available":[],"invites":[]}
        """
        var removedPhones: [String] = []
        var fullAccessSets: [String] = []
        var pairSetFails = false

        func pairSet(_ id: String, _ on: Bool) -> Bool {
            fullAccessSets.append("\(id) \(on)")
            return !pairSetFails
        }

        func run(_ args: [String]) -> Data? {
            calls.append(args)
            switch args.prefix(2).joined(separator: " ") {
            case "device list": return Data(listing.utf8)
            case "device audit": return Data(#"{"path":"/x","entries":[{"ts":"2026-10-22T07:12:00Z","event":"device.added","device":"peer:mini-7"}]}"#.utf8)
            case "device remove": return removeFails ? nil : Data("{}".utf8)
            default: return nil
            }
        }
    }

    @Test func devicesMergesTheCLIsDevicesAndThePhonesInWords() async throws {
        let cli = FakeCLI()
        let directory = DeviceDirectory(run: { cli.run($0) }, removePhone: { cli.removedPhones.append($0) })
        await directory.refresh()
        let rows = directory.rows(phones: [(id: "p1", name: "Lawrence's iPhone", connected: false)])
        #expect(rows.map(\.id) == ["peer:mini-7", "grant:new@manaflow.ai", "phone:p1"])
        #expect(rows[0].subtitle == "Runs your agents · Connected")
        #expect(rows[1].state == "pending")
        #expect(rows[1].detail?.contains("has not approved") == true)
        #expect(rows[2].subtitle == "Phone: approvals and terminals · Offline")
        #expect(directory.activityRows.first?.what == "Added")
        #expect(directory.activityRows.first?.subject == "mini-7")
        let page = try #require(try JSONSerialization.jsonObject(with: directory.pageData(phones: [])) as? [String: Any])
        #expect(page["remove_confirm_title"] as? String == "Remove for Good")
        #expect((page["rows"] as? [[String: Any]])?.count == 2)
    }

    @Test func removeGoesThroughOnePathAndReadsAgain() async {
        let cli = FakeCLI()
        let directory = DeviceDirectory(run: { cli.run($0) }, removePhone: { cli.removedPhones.append($0) })
        #expect(await directory.remove(id: "peer:mini-7") == nil)
        #expect(cli.calls.first == ["device", "remove", "peer:mini-7", "--yes", "--json"])
        #expect(cli.calls.dropFirst().first == ["device", "list", "--json"], "the list is read again after a remove")
        #expect(await directory.remove(id: "phone:p1") == nil)
        #expect(cli.removedPhones == ["p1"], "a phone is removed by the Mac's phone pairing, not the CLI")
        cli.removeFails = true
        #expect(await directory.remove(id: "peer:mini-7") != nil)
        #expect(directory.lastError != nil)
    }

    @Test func fullAccessIsAPairedClientsSwitchSetThroughAcpmux() async throws {
        let cli = FakeCLI()
        cli.listing = """
        {"network":{"kind":"tailscale","up":true},"devices":[
          {"id":"peer:mini-7","name":"mini-7","kind":"computer","roles":["runs-agents"],"state":"connected"},
          {"id":"paired:dv_leo","name":"leo-mbp","kind":"computer","roles":["uses-this"],"state":"offline","full_access":false}],
         "available":[],"invites":[]}
        """
        let directory = DeviceDirectory(run: { cli.run($0) }, removePhone: { cli.removedPhones.append($0) },
                                        setFullAccess: { cli.pairSet($0, $1) })
        await directory.refresh()
        let rows = directory.rows(phones: [(id: "p1", name: "Lawrence's iPhone", connected: true)])
        #expect(rows.map(\.fullAccess) == [nil, false, nil], "only a paired client machine has the setting, off by default")
        #expect(rows[1].fullAccessHelp == "Its chats edit files and run commands here without asking")
        #expect(rows[0].fullAccessHelp == nil)
        let page = try #require(try JSONSerialization.jsonObject(with: directory.pageData(phones: [])) as? [String: Any])
        let pageRows = try #require(page["rows"] as? [[String: Any]])
        #expect(page["full_access_title"] as? String == "Full access")
        #expect(pageRows[0]["full_access"] == nil)
        #expect(pageRows[1]["full_access"] as? Bool == false)

        cli.calls = []
        #expect(await directory.setFullAccess(id: "paired:dv_leo", on: true) == nil)
        #expect(cli.fullAccessSets == ["dv_leo true"], "acpmux gets the pairing id")
        #expect(cli.calls.first == ["device", "list", "--json"], "the list is read again after a change")
        #expect(await directory.setFullAccess(id: "peer:mini-7", on: true) == nil)
        #expect(cli.fullAccessSets.count == 1, "a row without the setting never reaches acpmux")
        cli.pairSetFails = true
        #expect(await directory.setFullAccess(id: "paired:dv_leo", on: true) == AddDeviceStrings.fullAccessOnFailed)
        #expect(await directory.setFullAccess(id: "paired:dv_leo", on: false) == AddDeviceStrings.fullAccessOffFailed)
        #expect(directory.lastError == AddDeviceStrings.fullAccessOffFailed)
    }

    /// Leo: "#2 seems reasonable i think... it's a gate that you can enable for your phone, which
    /// is an attack vector you opt in to". A phone paired with this Mac has its own acpmux record
    /// (role `phone`, named for the phone), and its row carries that record's switch, off by
    /// default. The record is never a row of its own, and a phone without one has no switch.
    @Test func aPairedPhoneHasTheFullAccessSwitchOfItsOwnRecord() async throws {
        let phone = "6A7B8C9D-0000-4000-8000-000000000002"
        let record = DeviceDirectory.phoneRecordName(phone)
        #expect(record == MobileHostPairedDevices.acpmuxRecordName(phone), "the app issues it under the same name")
        #expect(record == "phone-6a7b8c9d-0000-4000-8000-000000000002")
        let cli = FakeCLI()
        cli.listing = """
        {"network":{"kind":"tailscale","up":true},"devices":[
          {"id":"paired:dv_imposter","name":"\(record)","kind":"computer","roles":["uses-this"],"state":"offline","full_access":true},
          {"id":"paired:dv_phone","name":"\(record)","kind":"phone","roles":["uses-this"],"state":"connected","full_access":false},
          {"id":"paired:dv_gone","name":"phone-gone","kind":"phone","roles":["uses-this"],"state":"offline","full_access":true}],
         "available":[],"invites":[]}
        """
        let directory = DeviceDirectory(run: { cli.run($0) }, removePhone: { cli.removedPhones.append($0) },
                                        setFullAccess: { cli.pairSet($0, $1) })
        await directory.refresh()
        let rows = directory.rows(phones: [(id: phone, name: "Leo's iPhone", connected: true),
                                           (id: "not-issued", name: "Old iPhone", connected: false)])
        #expect(rows.map(\.id) == ["paired:dv_imposter", "phone:\(phone)", "phone:not-issued"],
                "a phone's record is not a row of its own")
        #expect(rows[1].fullAccess == false, "off by default")
        #expect(rows[1].fullAccessHelp == AddDeviceStrings.fullAccessHelp)
        #expect(rows[2].fullAccess == nil && rows[2].fullAccessHelp == nil, "no record yet: no switch")

        #expect(await directory.setFullAccess(id: "phone:\(phone)", on: true) == nil)
        #expect(cli.fullAccessSets == ["dv_phone true"], "the phone's own record, never a machine of the same name")
        #expect(await directory.setFullAccess(id: "phone:\(phone)", on: false) == nil)
        #expect(await directory.setFullAccess(id: "phone:not-issued", on: true) == nil)
        #expect(cli.fullAccessSets == ["dv_phone true", "dv_phone false"], "a phone without a record never reaches acpmux")
    }
}
