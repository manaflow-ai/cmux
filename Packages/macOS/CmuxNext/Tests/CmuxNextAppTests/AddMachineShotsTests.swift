import AppKit
import CmuxNextDesign
@testable import CmuxNextServer
import CmuxNextTestSupport
import Foundation
import Testing

/// Renders every state of the Add Machine card (picking with the tailnet list, the list loading,
/// no Tailscale, running, ready, failed, Check Machine with Fix) into one contact sheet, so a fleet run
/// returns the card's look as an artifact: `Packages/macOS/CmuxNext/.build/add-machine-shots.png`.
/// It also checks that every state draws something at a sane size.
@MainActor @Suite(.serialized, .closesItsWindows) struct AddMachineShotsTests {
    @Test func everyStateRendersToTheContactSheet() async throws {
        _ = NSApplication.shared
        var shots: [(String, NSImage)] = []
        for state in AddMachineShotState.allCases {
            let fixture = AddMachineFlowTests.FakeHost()
            let model = AddMachineModel(services: fixture.services())
            try await state.drive(model, fixture)
            let view = AddMachineHostView(model: model, material: .opaque)
            let image = try Self.render(view)
            #expect(image.size.width >= 300, "\(state) is \(image.size.width) pt wide")
            #expect(image.size.height >= 80, "\(state) is \(image.size.height) pt tall")
            shots.append((state.rawValue, image))
            fixture.live?.finish()
        }
        let sheet = AddServerShotsTests.contactSheet(shots)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/add-machine-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(sheet).write(to: out)
        print("add-machine-shots: wrote \(out.path)")
    }

    static func render(_ view: NSView) throws -> NSImage {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        window.setContentSize(NSSize(width: max(size.width, 320), height: max(size.height, 120)))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        window.close()
        return image
    }
}

/// The states the contact sheet shows, each reached through the model as the app reaches it.
enum AddMachineShotState: String, CaseIterable {
    case pick = "1 pick"
    case loading = "2 tailnet loading"
    case noTailscale = "3 no tailscale"
    case running = "4 running"
    case ready = "5 ready"
    case failed = "6 failed"
    case check = "7 check, fix"

    typealias Flow = AddMachineFlowTests

    @MainActor func drive(_ model: AddMachineModel, _ host: AddMachineFlowTests.FakeHost) async throws {
        switch self {
        case .pick:
            host.candidates = [
                HostCandidate(name: "huge-blue", dnsName: "huge-blue.tail1.ts.net.", ip: "100.64.0.2", os: "linux", online: true, alreadyPeer: false, sshOK: true),
                HostCandidate(name: "cmux16", dnsName: "cmux16.tail1.ts.net.", ip: "100.64.0.3", os: "macOS", online: true, alreadyPeer: true, sshOK: true, inApp: true),
                HostCandidate(name: "air-blue", dnsName: "air-blue.tail1.ts.net.", ip: "100.64.0.5", os: "macOS", online: true, alreadyPeer: true,
                              peer: "air-blue", peerURL: "ssh://air-blue"),
                HostCandidate(name: "big-red", dnsName: "big-red.tail1.ts.net.", ip: "100.64.0.4", os: "linux", online: true, alreadyPeer: false, sshOK: false),
            ]
            model.begin()
            for _ in 0..<100 where model.candidates == .loading { await Task.yield() }
            model.destination = "huge-blue.tail1.ts.net"
        case .loading:
            model.begin()
        case .noTailscale:
            host.candidates = nil
            model.begin()
            for _ in 0..<100 where model.candidates == .loading { await Task.yield() }
            model.destination = "leo@10.0.0.7"
        case .running:
            host.holdNextRun = true
            model.begin(destination: "huge-blue")
            model.perform(.add)
            await Task.yield()
            host.live?.yield(Flow.step("reach", "ok", "ssh leo@huge-blue answered"))
            host.live?.yield(Flow.step("install", "fixed", "pushed cmux-tui 5eac889"))
            for _ in 0..<100 where model.checklist.row(.daemon)?.status != .running { await Task.yield() }
        case .ready:
            host.scripts = [Array(Flow.okSteps.dropLast(3)) + [Flow.step("peer-back", "warn", "huge-blue cannot ssh back", fix: "Add this Mac's key on huge-blue."),
                                                        Flow.step("identity", "ok"), Flow.step("approvals", "ok"),
                                                        Flow.report("huge-blue", "huge-blue", ok: true, Flow.okSteps)]]
            model.begin(destination: "huge-blue")
            model.perform(.add)
            _ = await model.finished()
        case .failed:
            let fail = Flow.step("reach", "fail", "ssh: connect to host huge-blue port 22: Connection refused",
                                 fix: "Turn on Remote Login on huge-blue (System Settings > General > Sharing).")
            host.scripts = [[fail, Flow.report("huge-blue", "huge-blue", ok: false, [fail])]]
            model.begin(destination: "huge-blue")
            model.perform(.add)
            _ = await model.finished()
        case .check:
            let fail = Flow.step("daemon", "fail", "daemon status did not answer in 5 s", fix: "Run Fix to start the agent daemon again.")
            host.scripts = [[Flow.step("reach", "ok"), Flow.step("install", "ok"), fail,
                             Flow.report("huge-blue", "huge-blue", ok: false, [Flow.step("reach", "ok"), Flow.step("install", "ok"), fail])]]
            model.beginCheck(host: "leo@huge-blue", machineID: "ssh-1")
            _ = await model.finished()
        }
    }
}
