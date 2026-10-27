import Foundation
import IOSurface

/// A booted simulator's built-in display as the IOSurface the simulator
/// renders into. cmux draws that surface directly, so a frame costs no copy:
/// SimulatorKit's frame callback only says the surface changed.
///
/// A source delivers on main (`onFrame`, the phone stream's encoder) or
/// straight to a render queue (``init(device:queue:onFrame:)``, the phone
/// tab's screen): SimulatorKit then calls the callbacks on that queue and no
/// frame takes a main-thread turn (p03-rendering-114).
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
        let surface: SimulatorSurfaceReader
    }

    /// Frames straight to a queue: SimulatorKit calls `frame` there.
    private struct QueueDelivery {
        let queue: DispatchQueue
        let frame: @Sendable (IOSurface) -> Void
    }

    /// The frame, surfaces-changed and properties-changed blocks.
    private typealias Callbacks = (frame: AnyObject, changed: AnyObject, properties: AnyObject)

    private static let registerName =
        "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
    private let device: NSObject
    private let delivery: QueueDelivery?
    private var registration: Registration?
    /// Called on the main thread for every new frame and surface change (main delivery only).
    var onFrame: (@MainActor (IOSurface) -> Void)?

    init(device: NSObject) {
        self.device = device
        delivery = nil
    }

    /// A source whose frames SimulatorKit hands to `onFrame` on `queue`; only the surface shown at
    /// ``start()`` goes to it on the caller's thread.
    init(device: NSObject, queue: DispatchQueue, onFrame: @escaping @Sendable (IOSurface) -> Void) {
        self.device = device
        delivery = QueueDelivery(queue: queue, frame: onFrame)
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
            guard register(candidate, id: id, queue: .main, callbacks: mainCallbacks()) else { continue }
            registered.append(Registration(descriptor: candidate, id: id, surface: Self.surfaceReader(candidate)))
        }
        let builtIn = registered.first { Self.isBuiltIn($0.descriptor) && $0.surface() != nil }
            ?? registered.first { $0.surface() != nil }
        for other in registered where other.descriptor !== builtIn?.descriptor { Self.unregister(other.descriptor, other.id) }
        guard let builtIn else { throw unavailable }
        guard let delivery else {
            registration = builtIn
            if let surface { onFrame?(surface) }
            return
        }
        // The probe's callbacks run on main, after this turn: register the built-in display again on
        // the delivery queue first (its surface stays while one registration holds it), then drop the probe.
        let id = NSUUID()
        let registeredOnQueue = register(builtIn.descriptor, id: id, queue: delivery.queue,
                                         callbacks: Self.queueCallbacks(builtIn.surface, delivery.frame))
        Self.unregister(builtIn.descriptor, builtIn.id)
        guard registeredOnQueue else { throw unavailable }
        registration = Registration(descriptor: builtIn.descriptor, id: id, surface: builtIn.surface)
        // The surface shown now, before its next change, here on the caller's thread.
        if let surface { delivery.frame(surface) }
    }

    /// Unregisters the callbacks: no frame work happens until ``start()``.
    func stop() {
        if let registration { Self.unregister(registration.descriptor, registration.id) }
        registration = nil
    }

    private var unavailable: PhoneError { .unsupported(mode: .simulator, what: "a live screen with this Xcode") }

    private typealias Register = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void

    private func register(_ descriptor: NSObject, id: NSUUID, queue: DispatchQueue, callbacks: Callbacks) -> Bool {
        // The UUID, the callback queue and the three callback blocks.
        guard let method = PrivateMethod(descriptor, Self.registerName),
              let register = method.function(Register.self, returns: .void, arguments: Array(repeating: .object, count: 5)) else {
            return false
        }
        register(descriptor, method.selector, id, queue, callbacks.frame, callbacks.changed, callbacks.properties)
        return true
    }

    /// Blocks SimulatorKit calls on the queue we pass: main.
    private func mainCallbacks() -> Callbacks {
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
        return (frame as AnyObject, changed as AnyObject, properties as AnyObject)
    }

    /// Blocks SimulatorKit calls on the delivery queue: each reads the surface and hands it on. Made
    /// outside the main actor, so they carry no main-actor isolation.
    private nonisolated static func queueCallbacks(_ reader: SimulatorSurfaceReader,
                                                   _ frame: @escaping @Sendable (IOSurface) -> Void) -> Callbacks {
        let publish: @convention(block) () -> Void = { if let surface = reader() { frame(surface) } }
        return (publish as AnyObject, publish as AnyObject, publish as AnyObject)
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
    private nonisolated static func surfaceReader(_ descriptor: NSObject) -> SimulatorSurfaceReader {
        SimulatorSurfaceReader(framebuffer: privateGetter(descriptor, "framebufferSurface"), legacy: privateGetter(descriptor, "ioSurface"))
    }

    /// Current SimulatorKit marks the built-in display `isDefault`; older ones use screen type 0.
    private static func isBuiltIn(_ descriptor: NSObject) -> Bool {
        guard let properties = privateObject(descriptor, "screenProperties") else { return false }
        if let isDefault = privateNumber(properties, "isDefault") { return isDefault != 0 }
        return privateNumber(properties, "screenType") == 0
    }
}

/// A display descriptor's surface getter: read on main, and by the frame callbacks on the queue they
/// were registered with, as SimulatorKit expects of a client that registers its own queue.
nonisolated struct SimulatorSurfaceReader {
    private let framebuffer: (() -> NSObject?)?
    private let legacy: (() -> NSObject?)?

    init(framebuffer: (() -> NSObject?)?, legacy: (() -> NSObject?)?) {
        self.framebuffer = framebuffer
        self.legacy = legacy
    }

    func callAsFunction() -> IOSurface? {
        (framebuffer?() ?? legacy?()) as? IOSurface
    }
}
