import CmuxSimulator
import Foundation
import IOSurface
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator framebuffer port discovery")
@MainActor
struct SimulatorFramebufferPortDiscoveryTests {
    @Test("Framebuffer discovery uses the current ioPorts contract")
    func currentIOPortsContract() throws {
        let descriptor = SimulatorFramebufferDescriptorDouble()
        let port = SimulatorFramebufferPortDouble(descriptor: descriptor)
        let io = SimulatorFramebufferIODouble(ports: [port])
        let device = SimulatorFramebufferDeviceDouble(io: io)
        let context = try SimulatorRemoteRenderContext()
        var metadata: SimulatorDisplayMetadata?
        let framebuffer = SimulatorFramebuffer(renderContext: context) { value in
            metadata = value
        }

        try framebuffer.start(device: device)

        #expect(io.didRequestCurrentPorts)
        #expect(metadata?.width == 8)
        #expect(metadata?.height == 12)
    }
}

private final class SimulatorFramebufferDeviceDouble: NSObject {
    private let client: SimulatorFramebufferIODouble

    init(io: SimulatorFramebufferIODouble) {
        client = io
    }

    @objc dynamic func io() -> AnyObject { client }
}

private final class SimulatorFramebufferIODouble: NSObject {
    private let ports: [SimulatorFramebufferPortDouble]
    private(set) var didRequestCurrentPorts = false

    init(ports: [SimulatorFramebufferPortDouble]) {
        self.ports = ports
    }

    @objc dynamic func updateIOPorts() {}
    @objc dynamic func deviceIOPorts() -> [AnyObject] { [] }

    @objc dynamic func ioPorts() -> [AnyObject] {
        didRequestCurrentPorts = true
        return ports
    }
}

private final class SimulatorFramebufferPortDouble: NSObject {
    private let displayDescriptor: SimulatorFramebufferDescriptorDouble

    init(descriptor: SimulatorFramebufferDescriptorDouble) {
        displayDescriptor = descriptor
    }

    @objc dynamic func descriptor() -> AnyObject { displayDescriptor }
}

private final class SimulatorFramebufferDescriptorDouble: NSObject {
    private let surface: IOSurface

    override init() {
        surface = IOSurfaceCreate([
            kIOSurfaceWidth: 8,
            kIOSurfaceHeight: 12,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 32,
            kIOSurfaceAllocSize: 384,
            kIOSurfacePixelFormat: UInt32(0x4247_5241),
        ] as CFDictionary)!
        super.init()
    }

    @objc dynamic func framebufferSurface() -> AnyObject { surface }

    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    dynamic func registerScreenCallbacks(
        uuid _: NSUUID,
        callbackQueue _: DispatchQueue,
        frameCallback _: @escaping @convention(block) () -> Void,
        surfacesChangedCallback _: @escaping @convention(block) () -> Void,
        propertiesChangedCallback _: @escaping @convention(block) (AnyObject) -> Void
    ) {}

    @objc dynamic func unregisterScreenCallbacks(withUUID _: NSUUID) {}
}
