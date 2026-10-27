import Foundation
import IOSurface

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
    /// The display whose callbacks are registered, and its surface getter, resolved once.
    private struct Registration {
        let descriptor: NSObject
        let id: NSUUID
        let surface: () -> IOSurface?
    }

    private static let registerName =
        "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
    private let device: NSObject
    private var registration: Registration?
    /// Called on the main thread for every new frame and surface change.
    var onFrame: (@MainActor (IOSurface) -> Void)?

    init(device: NSObject) {
        self.device = device
    }

    /// The built-in display's surface now (nil before ``start()`` publishes one).
    var surface: IOSurface? {
        registration?.surface()
    }

    /// Registers for frames. Throws when this Xcode has no framebuffer callbacks.
    func start() throws {
        stop()
        guard let io = privateObject(device, "io") else { throw unavailable }
        privateVoid(io, "updateIOPorts")
        let ports = (privateObject(io, "ioPorts") as? [NSObject]) ?? (privateObject(io, "deviceIOPorts") as? [NSObject]) ?? []
        let selector = privateSelector(Self.registerName)
        let candidates = ports.compactMap { privateObject($0, "descriptor") }.filter { $0.responds(to: selector) }
        guard !candidates.isEmpty else { throw unavailable }
        // Surfaces appear only once callbacks are registered, so register on
        // every display descriptor, then keep the built-in one.
        var registered: [Registration] = []
        for candidate in candidates {
            let id = NSUUID()
            guard register(candidate, id: id) else { continue }
            registered.append(Registration(descriptor: candidate, id: id, surface: Self.surfaceReader(candidate)))
        }
        let builtIn = registered.first { Self.isBuiltIn($0.descriptor) && $0.surface() != nil }
            ?? registered.first { $0.surface() != nil }
        for other in registered where other.descriptor !== builtIn?.descriptor { Self.unregister(other.descriptor, other.id) }
        guard let builtIn else { throw unavailable }
        registration = builtIn
        if let surface { onFrame?(surface) }
    }

    /// Unregisters the callbacks: no frame work happens until ``start()``.
    func stop() {
        if let registration { Self.unregister(registration.descriptor, registration.id) }
        registration = nil
    }

    private var unavailable: PhoneError { .unsupported(mode: .simulator, what: "a live screen with this Xcode") }

    private typealias Register = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void

    private func register(_ descriptor: NSObject, id: NSUUID) -> Bool {
        // The UUID, the callback queue and the three callback blocks.
        guard let method = PrivateMethod(descriptor, Self.registerName),
              let register = method.function(Register.self, returns: .void, arguments: Array(repeating: .object, count: 5)) else {
            return false
        }
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
        register(descriptor, method.selector, id, DispatchQueue.main, frame as AnyObject, changed as AnyObject, properties as AnyObject)
        return true
    }

    private func publish() {
        guard let surface else { return }
        onFrame?(surface)
    }

    private static func unregister(_ descriptor: NSObject, _ id: NSUUID) {
        privateVoid(descriptor, "unregisterScreenCallbacksWithUUID:", id)
    }

    /// The display's framebuffer surface getter (`ioSurface` on older SimulatorKit), resolved once:
    /// every frame reads it.
    private static func surfaceReader(_ descriptor: NSObject) -> () -> IOSurface? {
        let framebuffer = privateGetter(descriptor, "framebufferSurface")
        let legacy = privateGetter(descriptor, "ioSurface")
        return { (framebuffer?() ?? legacy?()) as? IOSurface }
    }

    /// Current SimulatorKit marks the built-in display `isDefault`; older ones use screen type 0.
    private static func isBuiltIn(_ descriptor: NSObject) -> Bool {
        guard let properties = privateObject(descriptor, "screenProperties") else { return false }
        if let isDefault = privateNumber(properties, "isDefault") { return isDefault != 0 }
        return privateNumber(properties, "screenType") == 0
    }
}
