import Foundation
import Testing
@testable import CmuxNextPhone

/// The Mac side of a phone streaming a simulator (cmux-mobile-host `surface.rs`).
@MainActor
@Suite struct SimulatorSurfaceServerTests {
    func service(live: SimulatorKitHID? = nil) -> PhoneService {
        PhoneService(backend: XcodePhoneBackend(runner: FakePhoneRunner()), recordings: temporaryFolder(),
                     scratch: temporaryFolder(), live: live)
    }

    @Test func onlyABootedSimulatorStreams() async {
        let real = SimulatorSurfaceServer(service: service(), device: PhoneDeviceID(mode: .device, raw: "PHONE"))
        await #expect(throws: SimulatorSurfaceServer.Failure.self) { _ = try await real.start() }
        // No SimulatorKit (no Xcode, or one whose SimulatorKit does not load): refused with a reason, never a crash.
        let noKit = SimulatorSurfaceServer(service: service(live: SimulatorKitHID(developerDirectory: "/nonexistent")),
                                           device: PhoneDeviceID(mode: .simulator, raw: "SIM-1"))
        await #expect(throws: SimulatorSurfaceServer.Failure.self) { _ = try await noKit.start() }
    }

    /// The bytes cmux-mobile-host writes and reads (`SourceFrame::encode`, `SourceDeframer`).
    @Test func sf1MatchesHostd() throws {
        var wire = SurfaceSourceWire()
        // hostd's `encode {idr, kbps}` line, then an access unit as the Rust side frames one.
        let json = Data(#"{"idr":true,"kbps":2500,"t":"encode"}"#.utf8)
        var bytes = Data([1]) + withUnsafeBytes(of: UInt32(json.count).bigEndian) { Data($0) } + json
        bytes += Data([2, 0, 0, 0, 13, 1, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 1])
        wire.append(bytes.prefix(3))
        #expect(try wire.next() == nil)
        wire.append(bytes.dropFirst(3))
        #expect(try wire.next() == .json(["t": .string("encode"), "idr": .bool(true), "kbps": .number(2500)]))
        #expect(try wire.next() == .accessUnit(idr: true, captureMicros: 42, annexB: Data([0, 0, 0, 1])))
        #expect(try wire.next() == nil)
        // What the source writes reads back the same.
        var back = SurfaceSourceWire()
        back.append(SurfaceSourceWire.accessUnit(idr: false, captureMicros: 7, annexB: Data([9])))
        #expect(try back.next() == .accessUnit(idr: false, captureMicros: 7, annexB: Data([9])))
        var huge = SurfaceSourceWire()
        huge.append(Data([1, 0x7f, 0xff, 0xff, 0xff]))
        #expect(throws: SurfaceSourceWireError.tooLarge) { _ = try huge.next() }
    }

    /// Every key hostd lets a phone press has a HID usage here, and nothing else does.
    /// hostd's `encode` line carries a bitrate from the wire; `Int(1e30)` used to trap on the main actor.
    @Test func aWireBitrateIsClampedNeverATrap() {
        #expect(SurfaceFrameEncoder.bitrate(fromWire: 1e30) == 40_000)
        #expect(SurfaceFrameEncoder.bitrate(fromWire: -1e30) == 300)
        #expect(SurfaceFrameEncoder.bitrate(fromWire: .infinity) == 40_000)
        #expect(SurfaceFrameEncoder.bitrate(fromWire: .nan) == 4_000)
        #expect(SurfaceFrameEncoder.bitrate(fromWire: nil) == 4_000)
        #expect(SurfaceFrameEncoder.bitrate(fromWire: 2500) == 2_500)
    }

    @Test func theKeysHostdAllowsAreTheKeysTheSimulatorGets() {
        let hostd = ["Backspace", "Enter", "Tab", "Escape", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]
        #expect(hostd.allSatisfy { SimulatorSurfaceServer.Session.keyUsage($0) != nil })
        #expect(SimulatorSurfaceServer.Session.keyUsage("MetaLeft") == nil)
        #expect(SimulatorSurfaceServer.Session.keyUsage("Enter") == 0x28)
    }

    @Test func aRetinaScreenIsScaledToFitAndKeptEven() {
        let portrait = SurfaceFrameEncoder.encodedSize(width: 1206, height: 2622)
        #expect(portrait.width == 882 && portrait.height == 1920)
        let small = SurfaceFrameEncoder.encodedSize(width: 750, height: 1334)
        #expect(small.width == 750 && small.height == 1334)
        let landscape = SurfaceFrameEncoder.encodedSize(width: 2622, height: 1206)
        #expect(landscape.width == 1920 && landscape.height == 882)
    }
}
