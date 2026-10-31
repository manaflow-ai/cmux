import AppKit
import CmuxNextDesign
@testable import CmuxNextServer
import Foundation
import Testing

/// Renders every state of the Add Device card (the network list, loading, no network, the code
/// way, a new Mac or Linux computer, a new iPhone, a copied line) into one contact sheet, so a
/// fleet run returns the card's look as an artifact: `Packages/macOS/CmuxNext/.build/add-device-shots.png`.
/// It also checks that every state draws something at a sane size, with no SwiftUI host.
@MainActor @Suite(.serialized) struct AddDeviceShotsTests {
    enum Shot: String, CaseIterable {
        case network = "1 on your network"
        case loading = "2 looking"
        case noNetwork = "3 no Tailscale"
        case code = "4 it shows a code"
        case newMac = "5 new Mac or Linux"
        case copied = "6 line copied"
        case phone = "7 new iPhone"

        func drive(_ fake: AddDeviceFlowTests.Fake) async -> AddDeviceModel {
            let model = AddDeviceModel(services: fake.services())
            switch self {
            case .network:
                fake.listing = AddDeviceFlowTests.listing(available: [
                    .init(name: "studio", address: "studio.tail1234.ts.net", os: "macOS", mine: true),
                    .init(name: "build-box", address: "build-box.tail1234.ts.net", os: "linux", mine: false),
                    .init(name: "aws-m4pro-3", address: "aws-m4pro-3.tail1234.ts.net", os: "macOS", mine: false),
                ])
                await model.begin()
            case .loading:
                fake.holdNext = true
                Task { await model.begin() }
                while fake.hold == nil { await Task.yield() }
            case .noNetwork:
                fake.listing = AddDeviceFlowTests.listing(available: [], up: false)
                await model.begin(way: .network)
            case .code:
                await model.begin(way: .code)
            case .newMac:
                await model.begin(way: .newDevice)
            case .copied:
                await model.begin(way: .newDevice)
                model.perform(.copyLine)
            case .phone:
                await model.begin(way: .newDevice)
                model.choose(.phone)
            }
            return model
        }
    }

    @Test func everyStateRendersToTheContactSheet() async throws {
        _ = NSApplication.shared
        var shots: [(String, NSImage)] = []
        for shot in Shot.allCases {
            let fake = AddDeviceFlowTests.Fake()
            let model = await shot.drive(fake)
            let view = AddDeviceView(model: model)
            #expect(!Self.hostsSwiftUI(view), "\(shot) hosts SwiftUI")
            let image = try AddMachineShotsTests.render(view)
            #expect(image.size.width >= 400, "\(shot) is \(image.size.width) pt wide")
            #expect(image.size.height >= 160, "\(shot) is \(image.size.height) pt tall")
            shots.append((shot.rawValue, image))
            fake.hold?.resume()
        }
        let sheet = AddServerShotsTests.contactSheet(shots)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/add-device-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(sheet).write(to: out)
        print("add-device-shots: wrote \(out.path)")
    }

    /// The gallery of the "Any machine: one line" way (Labs labs.machineJoin): every look
    /// (``JoinLineLayout``) in every state, one contact sheet:
    /// `Packages/macOS/CmuxNext/.build/add-device-join-line-shots.png`. The app uses ``JoinLineLayout/card``.
    @Test func everyJoinLineLayoutAndStateRendersToTheGallery() async throws {
        _ = NSApplication.shared
        var shots: [(String, NSImage)] = []
        for layout in JoinLineLayout.allCases {
            for state in ["name", "showing", "under a minute", "joined", "expired"] {
                let fake = MachineJoinLineFlowTests.Fake()
                let devices = AddDeviceFlowTests.Fake()
                if state == "joined" { fake.rows = [MachineJoinLineFlowTests.Fake.joined("jt_1", name: "build-box")] }
                let model = fake.deviceModel(MachineJoinLineFlowTests.services(devices, fake))
                await model.begin(way: .joinLine)
                let join = try #require(model.joinLine)
                if state != "name" { await join.mint() }
                if state == "under a minute" { fake.now = fake.now.addingTimeInterval(560); join.tick() }
                if state == "expired" { fake.now = fake.now.addingTimeInterval(601); join.tick() }
                let view = AddDeviceView(model: model, joinLineLayout: layout)
                #expect(!Self.hostsSwiftUI(view), "\(layout) \(state) hosts SwiftUI")
                let image = try AddMachineShotsTests.render(view)
                #expect(image.size.width >= 400, "\(layout) \(state) is \(image.size.width) pt wide")
                shots.append(("\(layout.rawValue): \(state)", image))
                model.closeCard()
            }
        }
        let sheet = AddServerShotsTests.contactSheet(shots)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/add-device-join-line-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(sheet).write(to: out)
        print("add-device-join-line-shots: wrote \(out.path)")
    }

    @Test func theJoinLineControlsAreReachableByAccessibility() async throws {
        let fake = MachineJoinLineFlowTests.Fake()
        let devices = AddDeviceFlowTests.Fake()
        var concealed: [String] = []
        var services = MachineJoinLineFlowTests.services(devices, fake)
        services.copyConcealed = { concealed.append($0) }
        let model = fake.deviceModel(services)
        await model.begin(way: .joinLine)
        #expect(Self.identifiers(AddDeviceView(model: model)).contains("cmux.addDevice.joinLine.name"))
        await model.joinLine?.mint()
        let view = AddDeviceView(model: model)
        let ids = Self.identifiers(view)
        #expect(ids.contains("cmux.addDevice.joinLine.line"))
        #expect(ids.contains("cmux.addDevice.joinLine.countdown"))
        let copy = try #require(Self.find(view, id: "cmux.addDevice.button.copyJoinLine") as? NSButton)
        copy.performClick(nil)
        #expect(concealed == [fake.line.line], "the footer's Copy Line runs the concealed copy")
        model.closeCard()
    }

    @Test func theButtonsAndTheWaysAreReachableByAccessibility() async throws {
        let fake = AddDeviceFlowTests.Fake()
        let model = AddDeviceModel(services: fake.services())
        await model.begin()
        let view = AddDeviceView(model: model)
        let ids = Self.identifiers(view)
        #expect(ids.contains("cmux.addDevice.way"))
        #expect(ids.contains("cmux.addDevice.add.studio"))
        #expect(ids.contains("cmux.addDevice.button.cancel"))
        let add = try #require(Self.find(view, id: "cmux.addDevice.add.studio") as? NSButton)
        add.performClick(nil)
        #expect(fake.added.map(\.0) == ["studio.tail1234.ts.net"], "the row's Add runs the same perform as the model")
    }

    static func hostsSwiftUI(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("NSHostingView") || view.subviews.contains(where: hostsSwiftUI)
    }

    static func identifiers(_ view: NSView) -> [String] {
        [view.accessibilityIdentifier()] + view.subviews.flatMap(identifiers)
    }

    static func find(_ view: NSView, id: String) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews { if let hit = find(sub, id: id) { return hit } }
        if let scroll = view as? NSScrollView, let doc = scroll.documentView { return find(doc, id: id) }
        return nil
    }
}
