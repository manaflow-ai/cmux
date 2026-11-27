import Foundation
import IOSurface
import ObjectiveC.runtime

/// A booted simulator's built-in display as the IOSurface the simulator
/// renders into. cmux draws that surface directly (``PhoneScreenView`` sets
/// it as layer contents), so a frame costs no copy: SimulatorKit's frame
/// callback only tells the layer its contents changed.
///
/// Classic cmux rendered every frame into a shared-memory ring in a worker
/// process, then copied it again into a CGImage (two copies per frame). Here
/// there is no worker, no ring and no copy; ``stop()`` unregisters the
/// callbacks, so a hidden tab costs nothing.
@MainActor
final class SimulatorScreenSource {
    private let device: NSObject
    private var descriptor: NSObject?
    private var callbackID: NSUUID?
    /// Called on the main thread for every new frame and surface change.
    var onFrame: (@MainActor (IOSurface) -> Void)?

    init(device: NSObject) {
        self.device = device
    }

    /// The built-in display's surface now (nil before ``start()`` publishes one).
    var surface: IOSurface? {
        descriptor.flatMap { Self.surface(of: $0) }
    }

    /// Registers for frames. Throws when this Xcode has no framebuffer callbacks.
    func start() throws {
        stop()
        guard let io = privateObject(device, "io") else { throw unavailable }
        privateVoid(io, "updateIOPorts")
        let ports = (privateObject(io, "ioPorts") as? [NSObject]) ?? (privateObject(io, "deviceIOPorts") as? [NSObject]) ?? []
        let selector = privateSelector("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        let candidates = ports.compactMap { privateObject($0, "descriptor") }.filter { $0.responds(to: selector) }
        guard !candidates.isEmpty else { throw unavailable }
        // Surfaces appear only once callbacks are registered, so register on
        // every display descriptor, then keep the built-in one.
        var registered: [(NSObject, NSUUID)] = []
        for candidate in candidates {
            let id = NSUUID()
            guard register(candidate, id: id, selector: selector) else { continue }
            registered.append((candidate, id))
        }
        let builtIn = registered.first { Self.isBuiltIn($0.0) && Self.surface(of: $0.0) != nil }
            ?? registered.first { Self.surface(of: $0.0) != nil }
        for (other, id) in registered where other !== builtIn?.0 { Self.unregister(other, id) }
        guard let builtIn else { throw unavailable }
        descriptor = builtIn.0
        callbackID = builtIn.1
        if let surface { onFrame?(surface) }
    }

    /// Unregisters the callbacks: no frame work happens until ``start()``.
    func stop() {
        if let descriptor, let callbackID { Self.unregister(descriptor, callbackID) }
        descriptor = nil
        callbackID = nil
    }

    private var unavailable: PhoneError { .unsupported(mode: .simulator, what: "a live screen with this Xcode") }

    private func register(_ descriptor: NSObject, id: NSUUID, selector: Selector) -> Bool {
        guard let imp = class_getMethodImplementation(type(of: descriptor), selector) else { return false }
        // SimulatorKit calls these on the queue we pass: main.
        let frame: @convention(block) () -> Void = { [weak self] in
            // main-proof: registered with callbackQueue DispatchQueue.main, so SimulatorKit runs it on main.
            MainActor.assumeIsolated { self?.publish() }
        }
        let changed: @convention(block) () -> Void = { [weak self] in
            // main-proof: registered with callbackQueue DispatchQueue.main, so SimulatorKit runs it on main.
            MainActor.assumeIsolated { self?.publish() }
        }
        let properties: @convention(block) () -> Void = { [weak self] in
            // main-proof: registered with callbackQueue DispatchQueue.main, so SimulatorKit runs it on main.
            MainActor.assumeIsolated { self?.publish() }
        }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
        unsafeBitCast(imp, to: Function.self)(descriptor, selector, id, DispatchQueue.main,
                                              frame as AnyObject, changed as AnyObject, properties as AnyObject)
        return true
    }

    private func publish() {
        guard let surface else { return }
        onFrame?(surface)
    }

    private static func unregister(_ descriptor: NSObject, _ id: NSUUID) {
        let selector = privateSelector("unregisterScreenCallbacksWithUUID:")
        guard descriptor.responds(to: selector) else { return }
        _ = descriptor.perform(selector, with: id)
    }

    private static func surface(of descriptor: NSObject) -> IOSurface? {
        (privateObject(descriptor, "framebufferSurface") ?? privateObject(descriptor, "ioSurface")) as? IOSurface
    }

    /// Current SimulatorKit marks the built-in display `isDefault`; older ones use screen type 0.
    private static func isBuiltIn(_ descriptor: NSObject) -> Bool {
        guard let properties = privateObject(descriptor, "screenProperties") else { return false }
        if let isDefault = privateNumber(properties, "isDefault") { return isDefault != 0 }
        return privateNumber(properties, "screenType") == 0
    }
}
