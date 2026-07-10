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
        let descriptor = SimulatorFramebufferForwardingDescriptorDouble(
            target: SimulatorFramebufferDescriptorDouble()
        )
        let port = SimulatorFramebufferForwardingPortDouble(descriptor: descriptor)
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
    private let ports: [NSObject]
    private(set) var didRequestCurrentPorts = false

    init(ports: [NSObject]) {
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
    private let displayDescriptor: AnyObject

    init(descriptor: AnyObject) {
        displayDescriptor = descriptor
    }

    @objc dynamic func descriptor() -> AnyObject { displayDescriptor }
}

private final class SimulatorFramebufferForwardingPortDouble: NSObject {
    private let target: SimulatorFramebufferPortDouble

    init(descriptor: AnyObject) {
        target = SimulatorFramebufferPortDouble(descriptor: descriptor)
    }

    override func responds(to selector: Selector!) -> Bool {
        selector == NSSelectorFromString("descriptor") || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if selector == NSSelectorFromString("descriptor") { return target }
        return super.forwardingTarget(for: selector)
    }
}

private final class SimulatorFramebufferForwardingDescriptorDouble: NSObject {
    private let target: SimulatorFramebufferDescriptorDouble

    init(target: SimulatorFramebufferDescriptorDouble) {
        self.target = target
    }

    override func responds(to selector: Selector!) -> Bool {
        Self.forwardedSelectors.contains(selector) || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if Self.forwardedSelectors.contains(selector) { return target }
        return super.forwardingTarget(for: selector)
    }

    private static let forwardedSelectors = [
        NSSelectorFromString("framebufferSurface"),
        NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
                "surfacesChangedCallback:propertiesChangedCallback:"
        ),
        NSSelectorFromString("unregisterScreenCallbacksWithUUID:"),
    ]
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
        propertiesChangedCallback: @escaping @convention(block) () -> Void
    ) {
        propertiesChangedCallback()
    }

    @objc dynamic func unregisterScreenCallbacks(withUUID _: NSUUID) {}
}
