import Foundation
import IOSurface
import ObjectiveC

public final class CMUXSimulatorScreenStream: @unchecked Sendable {
    private let device: NSObject
    private let callbackQueue = DispatchQueue(label: "com.cmux.simulator.screen", qos: .userInteractive)
    private var ioClient: NSObject?
    private var descriptors: [NSObject] = []
    private var callbackIDs: [ObjectIdentifier: NSUUID] = [:]
    private var frameHandler: ((IOSurface) -> Void)?

    init(device: NSObject) {
        self.device = device
    }

    deinit {
        stop()
    }

    public func start(onFrame: @escaping (IOSurface) -> Void) throws {
        frameHandler = onFrame
        guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
            throw CMUXSimulatorError.screenUnavailable("Simulator IO client is unavailable.")
        }
        ioClient = io
        try wireFramebufferCallbacks(ioClient: io)
    }

    public func stop() {
        let selector = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for descriptor in descriptors {
            guard let uuid = callbackIDs[ObjectIdentifier(descriptor)],
                  descriptor.responds(to: selector) else {
                continue
            }
            descriptor.perform(selector, with: uuid)
        }
        descriptors.removeAll()
        callbackIDs.removeAll()
        ioClient = nil
        frameHandler = nil
    }

    private func wireFramebufferCallbacks(ioClient: NSObject) throws {
        ioClient.perform(NSSelectorFromString("updateIOPorts"))
        guard let ports = ioClient.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw CMUXSimulatorError.screenUnavailable("SimulatorKit returned no IO ports.")
        }

        let portIdentifier = NSSelectorFromString("portIdentifier")
        let descriptorSelector = NSSelectorFromString("descriptor")
        let framebufferSurface = NSSelectorFromString("framebufferSurface")
        let candidates = ports.compactMap { port -> NSObject? in
            guard port.responds(to: portIdentifier),
                  let identifier = port.perform(portIdentifier)?.takeUnretainedValue(),
                  "\(identifier)" == "com.apple.framebuffer.display",
                  port.responds(to: descriptorSelector),
                  let descriptor = port.perform(descriptorSelector)?.takeUnretainedValue() as? NSObject,
                  descriptor.responds(to: framebufferSurface) else {
                return nil
            }
            return descriptor
        }

        guard !candidates.isEmpty else {
            throw CMUXSimulatorError.screenUnavailable("No framebuffer display descriptor is available.")
        }

        descriptors = candidates
        for descriptor in candidates {
            try registerCallbacks(on: descriptor)
        }
        captureLatest()
    }

    private func registerCallbacks(on descriptor: NSObject) throws {
        let selector = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
            "surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard descriptor.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: descriptor), selector) else {
            throw CMUXSimulatorError.screenUnavailable("Framebuffer callbacks are unavailable.")
        }

        let uuid = NSUUID()
        callbackIDs[ObjectIdentifier(descriptor)] = uuid

        let frameCallback: @convention(block) () -> Void = { [weak self] in
            self?.callbackQueue.async {
                self?.captureLatest()
            }
        }
        let surfacesChangedCallback: @convention(block) () -> Void = { [weak self] in
            self?.callbackQueue.async {
                self?.captureLatest()
            }
        }
        let propertiesChangedCallback: @convention(block) () -> Void = {}

        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            AnyObject,
            AnyObject,
            AnyObject,
            AnyObject
        ) -> Void

        unsafeBitCast(implementation, to: Function.self)(
            descriptor,
            selector,
            uuid,
            callbackQueue as AnyObject,
            frameCallback as AnyObject,
            surfacesChangedCallback as AnyObject,
            propertiesChangedCallback as AnyObject
        )
    }

    private func captureLatest() {
        let selector = NSSelectorFromString("framebufferSurface")
        var bestSurface: IOSurface?
        var bestArea = 0

        for descriptor in descriptors {
            guard let surfaceObject = descriptor.perform(selector)?.takeUnretainedValue() else {
                continue
            }
            let surface = unsafeBitCast(surfaceObject, to: IOSurface.self)
            let area = IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface)
            if area > bestArea {
                bestSurface = surface
                bestArea = area
            }
        }

        if let bestSurface {
            frameHandler?(bestSurface)
        }
    }
}
