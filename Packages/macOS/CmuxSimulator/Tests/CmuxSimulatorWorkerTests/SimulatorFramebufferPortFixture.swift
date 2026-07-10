import Foundation
import IOSurface

final class SimulatorFramebufferPortFixture {
    private final class Device: NSObject {
        private let client: IO

        init(io: IO) {
            client = io
        }

        @objc dynamic func io() -> AnyObject { client }
    }

    private final class IO: NSObject {
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

    private final class Port: NSObject {
        private let displayDescriptor: AnyObject

        init(descriptor: AnyObject) {
            displayDescriptor = descriptor
        }

        @objc dynamic func descriptor() -> AnyObject { displayDescriptor }
    }

    private final class ForwardingPort: NSObject {
        private let target: Port

        init(descriptor: AnyObject) {
            target = Port(descriptor: descriptor)
        }

        override func responds(to selector: Selector!) -> Bool {
            selector == NSSelectorFromString("descriptor") || super.responds(to: selector)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if selector == NSSelectorFromString("descriptor") { return target }
            return super.forwardingTarget(for: selector)
        }
    }

    private final class ForwardingDescriptor: NSObject {
        private let target: Descriptor

        init(target: Descriptor) {
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

    private final class Descriptor: NSObject {
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

    private let io: IO
    let device: NSObject

    var didRequestCurrentPorts: Bool { io.didRequestCurrentPorts }

    init() {
        let descriptor = ForwardingDescriptor(target: Descriptor())
        let port = ForwardingPort(descriptor: descriptor)
        let io = IO(ports: [port])
        self.io = io
        device = Device(io: io)
    }
}
