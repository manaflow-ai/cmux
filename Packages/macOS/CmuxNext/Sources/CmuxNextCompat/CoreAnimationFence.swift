public import Darwin
public import QuartzCore
import Foundation
import ObjectiveC

/// SPIKE (scratch/frame-owner-s4-fence-spike-nomerge, never merged): Core Animation's fence ports, the mechanism of
/// WebKit's resize sync, behind ONE adapter. Every selector is SPI, so each is resolved at run time
/// (`NSClassFromString`, `class_getInstanceMethod`, `class_getClassMethod`); nothing private is linked. When this OS
/// lacks a selector, the initializer returns nil and the caller runs with no fence.
///
/// The model (WebKit `TiledCoreAnimationDrawingAreaProxy::createFence`, `LayerHostingContext::setFencePort`):
/// `-[CAContext createFencePort]` puts a fence in the creating thread's current transaction on that context and returns
/// a send right to it. Every transaction that takes the port (`-[CAContext setFencePort:]`) joins the fence. The render
/// server holds the fenced transactions until every send right to the port is gone, then applies them together.
public nonisolated final class CoreAnimationFence: @unchecked Sendable {
    /// A fence port: a Mach send right.
    public typealias Port = mach_port_t

    private typealias CreateFunction = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias SetFunction = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias VoidFunction = @convention(c) (AnyObject, Selector) -> Void

    /// The CAContext (an SPI class: held as an object).
    public let context: NSObject
    private let create: CreateFunction
    private let set: SetFunction
    private let invalidate: VoidFunction?

    /// The fence of the context that draws `layer` (`-[CALayer context]`); nil when this OS lacks a selector or the
    /// layer is not in a context yet.
    public convenience init?(contextOf layer: CALayer) {
        guard let context = Self.object(layer, "context") else { return nil }
        self.init(context: context)
    }

    /// The fence of `context`, a CAContext; nil when it lacks `createFencePort` or `setFencePort:`.
    public init?(context: NSObject) {
        guard let create = Self.instanceFunction(context, "createFencePort", as: CreateFunction.self),
              let set = Self.instanceFunction(context, "setFencePort:", as: SetFunction.self) else { return nil }
        self.context = context
        self.create = create
        self.set = set
        invalidate = Self.instanceFunction(context, "invalidateFences", as: VoidFunction.self)
    }

    /// Puts a fence in this thread's current transaction on the context and returns its port, or nil
    /// (`MACH_PORT_NULL`). The caller owns the send right: ``release(_:)`` it once every joined transaction committed.
    public func createFencePort() -> Port? {
        let port = create(context, NSSelectorFromString("createFencePort"))
        return port == 0 ? nil : port
    }

    /// Joins this thread's current transaction on the context to the fence `port` (call between
    /// `CATransaction.begin()` and `commit()`).
    public func join(_ port: Port) {
        set(context, NSSelectorFromString("setFencePort:"), port)
    }

    /// Lets every fenced transaction on the context go (`-[CAContext invalidateFences]`), when this OS has it.
    /// - Returns: Whether the OS had the selector.
    @discardableResult
    public func invalidateFences() -> Bool {
        guard let invalidate else { return false }
        invalidate(context, NSSelectorFromString("invalidateFences"))
        return true
    }

    /// Gives up one send right to `port` (`mach_port_deallocate`, as WebKit's `MachSendRight` does after its commit).
    public static func release(_ port: Port) {
        mach_port_deallocate(mach_task_self_, port)
    }

    /// Which of the selectors and classes the fence and ``CoreAnimationHostedContext`` use this OS has, by name.
    public static func probe(layer: CALayer?) -> [String: Bool] {
        var found: [String: Bool] = [:]
        let contextClass: AnyClass? = NSClassFromString("CAContext")
        found["class CAContext"] = contextClass != nil
        for name in ["createFencePort", "setFencePort:", "setFencePort:commitHandler:", "invalidateFences", "contextId",
                     "setLayer:", "layer", "invalidate"] {
            found["-[CAContext \(name)]"] = contextClass.map { class_getInstanceMethod($0, NSSelectorFromString(name)) != nil } ?? false
        }
        for name in ["remoteContextWithOptions:", "contextWithCGSConnection:options:", "localContext", "allContexts",
                     "currentContext"] {
            found["+[CAContext \(name)]"] = contextClass.map { class_getClassMethod($0, NSSelectorFromString(name)) != nil } ?? false
        }
        for name in ["setFencePort:", "addCommitHandler:forPhase:", "activate", "synchronize"] {
            found["+[CATransaction \(name)]"] = class_getClassMethod(CATransaction.self, NSSelectorFromString(name)) != nil
        }
        found["-[CALayer context]"] = class_getInstanceMethod(CALayer.self, NSSelectorFromString("context")) != nil
        let host: AnyClass? = NSClassFromString("CALayerHost")
        found["class CALayerHost"] = host != nil
        found["-[CALayerHost setContextId:]"] = host.map { class_getInstanceMethod($0, NSSelectorFromString("setContextId:")) != nil } ?? false
        found["symbol CGSMainConnectionID"] = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") != nil
        if let window: AnyClass = NSClassFromString("NSWindow") {
            found["-[NSWindow _layerContext]"] = class_getInstanceMethod(window, NSSelectorFromString("_layerContext")) != nil
        }
        if let layer {
            found["layer.context non-nil"] = object(layer, "context") != nil
        }
        return found
    }

    static func object(_ target: NSObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    static func instanceFunction<F>(_ target: NSObject, _ name: String, as _: F.Type) -> F? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: F.self)
    }
}

/// SPIKE: a layer tree in its own CAContext, shown in a window's tree through a `CALayerHost`, as WebKit's and
/// Chromium's remote layers are, in one process. A fence made from ``fence`` holds only this context's commits.
/// nil when this OS lacks a selector or class.
public nonisolated final class CoreAnimationHostedContext: @unchecked Sendable {
    /// The layer to add to the window's tree: it shows the context's root layer.
    public let hostLayer: CALayer
    /// The fence of the hosted context.
    public let fence: CoreAnimationFence
    /// The hosted CAContext (retained for as long as it is shown).
    public let context: NSObject

    private typealias ContextIdFunction = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias SetContextIdFunction = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias RemoteFunction = @convention(c) (AnyObject, Selector, NSDictionary) -> Unmanaged<NSObject>?
    private typealias CGSFunction = @convention(c) (AnyObject, Selector, UInt32, NSDictionary) -> Unmanaged<NSObject>?
    private typealias MainConnection = @convention(c) () -> UInt32

    /// Puts `root` in a new remote CAContext of this process and makes a host layer for it.
    public init?(root: CALayer) {
        guard let contextClass = NSClassFromString("CAContext"), let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type
        else { return nil }
        var made: NSObject?
        let remote = NSSelectorFromString("remoteContextWithOptions:")
        if let method = class_getClassMethod(contextClass, remote) {
            let function = unsafeBitCast(method_getImplementation(method), to: RemoteFunction.self)
            made = function(contextClass, remote, NSDictionary())?.takeUnretainedValue()
        }
        let cgs = NSSelectorFromString("contextWithCGSConnection:options:")
        if made == nil, let method = class_getClassMethod(contextClass, cgs),
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") {
            let connection = unsafeBitCast(symbol, to: MainConnection.self)()
            let function = unsafeBitCast(method_getImplementation(method), to: CGSFunction.self)
            made = function(contextClass, cgs, connection, NSDictionary())?.takeUnretainedValue()
        }
        guard let context = made,
              let fence = CoreAnimationFence(context: context),
              let contextId = CoreAnimationFence.instanceFunction(context, "contextId", as: ContextIdFunction.self)
        else { return nil }
        let setLayer = NSSelectorFromString("setLayer:")
        guard context.responds(to: setLayer) else { return nil }
        context.perform(setLayer, with: root)
        let host = hostClass.init()
        let setContextId = NSSelectorFromString("setContextId:")
        guard let setId = CoreAnimationFence.instanceFunction(host, setContextId, as: SetContextIdFunction.self) else { return nil }
        setId(host, setContextId, contextId(context, NSSelectorFromString("contextId")))
        self.context = context
        self.fence = fence
        hostLayer = host
    }
}
