import CmuxBrowserStream
import CmuxLink
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("Simulator channels on the browser rd path (lane C14)")
struct SimulatorChannelTests {
    static let udid = "4E7B2C1A-9D3F-4B8E-A1C2-0F5D6E7A8B9C"
    static let screen = RbScreenInfo(cssWidth: 393, cssHeight: 852, scale: 3, refreshHz: 60)

    static func touch(_ kind: RbPointerKind, _ x: Double, _ y: Double, buttons: UInt8) -> RbInputEvent {
        .pointer(kind: kind, x: x, y: y, button: 0, buttons: buttons, clickCount: 1, modifiers: [], pointerType: "touch")
    }

    @Test func framesFlowAndTouchesArriveInDevicePoints() async throws {
        let host = FakeSimulators()
        let harness = try await PhoneHarness(handlers: MobileSimulators(host: host).registering())
        let link = harness.linkClient()
        let client = BrowserStreamClient(client: link, params: BrowserChannelParams(simulator: Self.udid, screen: Self.screen))
        defer { Task { await client.close(); await link.close(); await harness.shutdown() } }
        let opened = try await client.open()
        #expect(opened.caps == ["clipboard"])
        var frames = client.frames.makeAsyncIterator()
        nonisolated(unsafe) var iterator = frames
        let first = try await within { await iterator.next() }
        frames = iterator
        #expect(first?.isKeyframe == true)
        try await client.send(Self.touch(.down, 10, 20, buttons: 1))
        try await client.send(Self.touch(.move, 30, 40, buttons: 1))
        try await client.send(Self.touch(.move, 50, 60, buttons: 0))
        try await client.send(Self.touch(.up, 31, 41, buttons: 0))
        try await client.send(Self.touch(.move, 70, 80, buttons: 0))
        try await client.send(.imeCommit(text: "hi", replacement: nil))
        await host.device.waitForInputs(5)
        // A move after the touch ended (pointer hover) is not a touch.
        #expect(await host.device.touches == [SimulatorTouch(phase: .began, x: 10, y: 20),
                                              SimulatorTouch(phase: .moved, x: 30, y: 40),
                                              SimulatorTouch(phase: .moved, x: 50, y: 60),
                                              SimulatorTouch(phase: .ended, x: 31, y: 41)])
        #expect(await host.device.texts == ["hi"])
    }

    @Test func navigationIsRefused() async throws {
        let host = FakeSimulators()
        let harness = try await PhoneHarness(handlers: MobileSimulators(host: host).registering())
        let link = harness.linkClient()
        let client = BrowserStreamClient(client: link, params: BrowserChannelParams(simulator: Self.udid, screen: Self.screen))
        defer { Task { await client.close(); await link.close(); await harness.shutdown() } }
        _ = try await client.open()
        let refusal = try await within { try await client.navigate(to: URL(string: "https://example.com")!) }
        #expect(refusal == .notAllowed)
    }

    @Test func anUnknownOrShutdownSimulatorIsRefused() async throws {
        let host = FakeSimulators()
        let harness = try await PhoneHarness(handlers: MobileSimulators(host: host).registering())
        defer { Task { await harness.shutdown() } }
        try await harness.hello()
        var params = BrowserChannelParams(simulator: "00000000-0000-0000-0000-000000000000", screen: Self.screen).params
        let (_, unknown) = try await harness.open(.simulator, id: 1, params: params)
        #expect(unknown["code"] == "simulator.not_found")
        params = BrowserChannelParams(simulator: FakeSimulators.shutdownUDID, screen: Self.screen).params
        let (_, off) = try await harness.open(.simulator, id: 3, params: params)
        #expect(off["code"] == "simulator.not_found")
        let (_, bad) = try await harness.open(.simulator, id: 5, params: ["udid": "../etc", "service": "rb/1"])
        #expect(bad["code"] == "validation.invalid")
    }

    @Test func listPutsBootedFirstAndSimctlParses() async throws {
        let harness = try await PhoneHarness(handlers: MobileSimulators(host: FakeSimulators()).registering())
        defer { Task { await harness.shutdown() } }
        try await harness.hello()
        let (rpc, _) = try await harness.open(.rpc, id: 1)
        try await rpc.send(frame: .read(ReadFrame(id: 1, op: "simulator.list", params: .object([:]))))
        let reply = try await PhoneHarness.nextJSON(rpc)
        let list = try #require(reply["value"]).decode(as: SimulatorListResult.self)
        #expect(list.simulators.map(\.state) == [.booted, .shutdown])
        let json = Data("""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"\(Self.udid)","name":"iPhone 17 Pro","state":"Booted","isAvailable":true},
          {"udid":"\(FakeSimulators.shutdownUDID)","name":"iPad","state":"Shutdown","isAvailable":false}],
          "com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[{"udid":"X","name":"Watch","state":"Booted"}]}}
        """.utf8)
        #expect(try SimctlSimulatorList().parse(json) == [SimulatorInfo(udid: Self.udid, name: "iPhone 17 Pro",
                                                                        runtime: "iOS 27.0", state: .booted)])
    }
}

final class FakeSimulators: SimulatorCaptureHost {
    static let shutdownUDID = "11111111-2222-3333-4444-555555555555"
    let device = FakeSimulatorDevice()

    func simulators() async throws -> [SimulatorInfo] {
        [SimulatorInfo(udid: Self.shutdownUDID, name: "iPad", runtime: "iOS 27.0", state: .shutdown),
         SimulatorInfo(udid: SimulatorChannelTests.udid, name: "iPhone 17 Pro", runtime: "iOS 27.0", state: .booted)]
    }

    func attach(_ request: SimulatorAttachRequest) async throws -> any SimulatorAttachment {
        guard request.udid == SimulatorChannelTests.udid else { throw SimulatorCaptureError.notFound }
        return device
    }
}

actor FakeSimulatorDevice: SimulatorAttachment {
    nonisolated let source = FakeVideoSource()
    nonisolated var video: any BrowserVideoSource { source }
    nonisolated let inputCount = CountSignal()
    private(set) var touches: [SimulatorTouch] = []
    private(set) var texts: [String] = []

    var screen: SimulatorScreen { SimulatorScreen(pointWidth: 393, pointHeight: 852, scale: 3) }

    func touch(_ touch: SimulatorTouch) async {
        touches.append(touch)
        await inputCount.increment()
    }

    func text(_ text: String) async {
        texts.append(text)
        await inputCount.increment()
    }

    func key(_ event: RbKeyEvent) async {}
    func pasteboard(_ text: String) async {}
    func ended() async -> AsyncStream<String> { AsyncStream { _ in } }
    func detach() async {}

    func waitForInputs(_ count: Int) async {
        await inputCount.wait(atLeast: count)
    }
}
