import AppKit
@testable import CmuxNextServer
import Foundation
import Testing

/// Add Device (plans/cmux-next/add-device-DESIGN.md): the card opens on the network way when the
/// network lists computers that are not added, else on "Set up a new device"; a pick hands off to
/// Add Machine with the address, "Enter Code…" to Add Server, Copy Line copies the platform's line,
/// and a late listing never moves a person who chose a way. Settings > Devices merges the CLI's
/// devices and the Mac's phones, removes through one path, and reads again after a remove.
@MainActor @Suite(.serialized) struct AddDeviceFlowTests {
    final class Fake {
        var listing: DeviceListing? = AddDeviceFlowTests.listing(available: [
            DeviceListing.Available(name: "studio", address: "studio.tail1234.ts.net", os: "macOS", mine: true),
        ])
        var hold: CheckedContinuation<Void, Never>?
        var holdNext = false
        var added: [(String, String)] = []
        var byName = 0
        var codes = 0
        var copied: [String] = []

        func services() -> AddDeviceServices {
            AddDeviceServices(
                list: { [self] in
                    if holdNext {
                        holdNext = false
                        await withCheckedContinuation { hold = $0 }
                    }
                    return listing
                },
                addComputer: { [self] address, name in added.append((address, name)) },
                addByName: { [self] in byName += 1 },
                enterCode: { [self] in codes += 1 },
                copy: { [self] in copied.append($0) })
        }
    }

    static func listing(available: [DeviceListing.Available], up: Bool = true) -> DeviceListing {
        DeviceListing(network: .init(kind: up ? "tailscale" : "none", up: up, this: up ? "lawrence-mbp" : nil,
                                     detail: up ? nil : "Tailscale is not installed on this machine."),
                      devices: [DeviceListing.Device(id: "peer:mini-7", name: "mini-7", roles: ["runs-agents"], state: "connected", os: "macOS")],
                      available: available)
    }

    @Test func opensOnTheNetworkWayWhenTheNetworkListsAComputer() async {
        let fake = Fake()
        let model = AddDeviceModel(services: fake.services())
        await model.begin()
        #expect(model.way == .network)
        #expect(model.available.map(\.name) == ["studio"])
        #expect(model.buttons.map(\.action) == [.cancel, .otherComputer])
    }

    @Test func opensOnSetUpANewDeviceWhenNothingIsLeftToAdd() async {
        let fake = Fake()
        fake.listing = Self.listing(available: [])
        let model = AddDeviceModel(services: fake.services())
        await model.begin()
        #expect(model.way == .newDevice)
        #expect(model.buttons.map(\.action) == [.cancel, .copyLine])
        #expect(model.buttons.last?.key == .return)
    }

    @Test func noCLIShowsTheNetworkAsUnavailableAndStillOffersAName() async {
        let fake = Fake()
        fake.listing = nil
        let model = AddDeviceModel(services: fake.services())
        await model.begin(way: .network)
        #expect(model.candidates == .unavailable)
        #expect(model.perform(.otherComputer))
        #expect(fake.byName == 1)
    }

    @Test func aNetworkThatIsDownSaysWhy() async {
        let fake = Fake()
        fake.listing = Self.listing(available: [], up: false)
        let model = AddDeviceModel(services: fake.services())
        await model.begin(way: .network)
        #expect(model.networkProblem == "Tailscale is not installed on this machine.")
    }

    @Test func pickingAComputerHandsItToAddMachineAndCloses() async throws {
        let fake = Fake()
        let model = AddDeviceModel(services: fake.services())
        await model.begin()
        let studio = try #require(model.available.first)
        #expect(model.perform(.pick(studio)))
        #expect(fake.added.map(\.0) == ["studio.tail1234.ts.net"])
        #expect(fake.added.map(\.1) == ["studio"])
    }

    @Test func enterCodeOpensAddServerAndCopyLineCopiesThePlatformsLine() async {
        let fake = Fake()
        let model = AddDeviceModel(services: fake.services())
        await model.begin(way: .code)
        #expect(model.buttons.map(\.action) == [.cancel, .enterCode])
        #expect(model.perform(.enterCode))
        #expect(fake.codes == 1)
        model.choose(.newDevice)
        model.choose(.windows)
        #expect(!model.perform(.copyLine), "the card stays open after a copy")
        #expect(fake.copied == [AddDevicePlatform.windows.setupLine!])
        #expect(model.copied)
        model.choose(.phone)
        #expect(!model.copied)
        #expect(model.buttons.map(\.action) == [.done])
    }

    @Test func aLateListingNeverMovesAPersonWhoChoseAWay() async {
        let fake = Fake()
        fake.listing = Self.listing(available: [])
        fake.holdNext = true
        let model = AddDeviceModel(services: fake.services())
        let begin = Task { await model.begin() }
        while fake.hold == nil { await Task.yield() }
        model.choose(.code)
        fake.hold?.resume()
        await begin.value
        #expect(model.way == .code, "an empty list would have moved it to newDevice")
    }

    @Test func theSetupLinesInstallCmuxAndShowAPairingCode() {
        #expect(AddDevicePlatform.macOrLinux.setupLine?.hasPrefix("curl -fsSL https://cmux.com/tui/install-static.sh | sh") == true)
        #expect(AddDevicePlatform.macOrLinux.setupLine?.hasSuffix("cmux server pair") == true)
        #expect(AddDevicePlatform.windows.setupLine?.contains("install-static.ps1") == true)
        #expect(AddDevicePlatform.phone.setupLine == nil)
    }

    @Test func theCLIsListingParses() throws {
        let json = """
        {"network":{"kind":"tailscale","up":true,"this":"lawrence-mbp"},
         "devices":[{"id":"peer:mini-7","name":"mini-7","kind":"computer","roles":["runs-agents"],"state":"connected",
                     "os":"macOS","reach":{"network":"tailscale","address":"mini-7.ts.net","ips":[],"online":true},
                     "via":[{"store":"peer","name":"mini-7"}],"added_at":"2026-10-22T07:12:00Z"}],
         "available":[{"name":"studio","address":"studio.ts.net","os":"macOS","mine":true}],
         "invites":[{"id":"tk_1","role":"client","label":null,"expires_at":"2026-10-22T08:00:00Z"}],
         "notes":[]}
        """
        let listing = try DeviceListing.parse(Data(json.utf8))
        #expect(listing.devices.first?.addedAt == "2026-10-22T07:12:00Z")
        #expect(listing.available.first?.mine == true)
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
}
