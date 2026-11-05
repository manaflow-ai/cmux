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
// crash-allow: immutable after init (a CAContext and three function pointers); CAContext is thread-safe under CA's own lock.
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
        let port = create(context, CoreAnimationFence.selector("createFencePort"))
        return port == 0 ? nil : port
    }

    /// Joins this thread's current transaction on the context to the fence `port` (call between
    /// `CATransaction.begin()` and `commit()`).
    public func join(_ port: Port) {
        set(context, CoreAnimationFence.selector("setFencePort:"), port)
    }

    /// Lets every fenced transaction on the context go (`-[CAContext invalidateFences]`), when this OS has it.
    /// - Returns: Whether the OS had the selector.
    @discardableResult
    public func invalidateFences() -> Bool {
        guard let invalidate else { return false }
        invalidate(context, CoreAnimationFence.selector("invalidateFences"))
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
            found["-[CAContext \(name)]"] = contextClass.map { class_getInstanceMethod($0, CoreAnimationFence.selector(name)) != nil } ?? false
        }
        for name in ["remoteContextWithOptions:", "contextWithCGSConnection:options:", "localContext", "allContexts",
                     "currentContext"] {
            found["+[CAContext \(name)]"] = contextClass.map { class_getClassMethod($0, CoreAnimationFence.selector(name)) != nil } ?? false
        }
        for name in ["setFencePort:", "addCommitHandler:forPhase:", "activate", "synchronize"] {
            found["+[CATransaction \(name)]"] = class_getClassMethod(CATransaction.self, CoreAnimationFence.selector(name)) != nil
        }
        found["-[CALayer context]"] = class_getInstanceMethod(CALayer.self, CoreAnimationFence.selector("context")) != nil
        let host: AnyClass? = NSClassFromString("CALayerHost")
        found["class CALayerHost"] = host != nil
        found["-[CALayerHost setContextId:]"] = host.map { class_getInstanceMethod($0, CoreAnimationFence.selector("setContextId:")) != nil } ?? false
        found["symbol CGSMainConnectionID"] = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") != nil
        if let window: AnyClass = NSClassFromString("NSWindow") {
            found["-[NSWindow _layerContext]"] = class_getInstanceMethod(window, CoreAnimationFence.selector("_layerContext")) != nil
        }
        if let layer {
            found["layer.context non-nil"] = object(layer, "context") != nil
        }
        return found
    }

    /// The selector named `name`, from the compile-time table of ``CoreAnimationSPI`` (no string lookup). Every caller
    /// checks it with `class_getInstanceMethod`, `class_getClassMethod` or `responds(to:)` before it calls it, so a
    /// selector this OS lacks is never sent.
    static func selector(_ name: String) -> Selector {
        selectors[name] ?? #selector(NSObject.description)
    }

    private static let selectors: [String: Selector] = {
        let list: [Selector] = [
            #selector(CoreAnimationSPI.createFencePort), #selector(CoreAnimationSPI.setFencePort(_:)),
            #selector(CoreAnimationSPI.setFencePort(_:commitHandler:)), #selector(CoreAnimationSPI.invalidateFences),
            #selector(CoreAnimationSPI.contextId), #selector(CoreAnimationSPI.setLayer(_:)), #selector(CoreAnimationSPI.layer),
            #selector(CoreAnimationSPI.invalidate), #selector(CoreAnimationSPI.remoteContextWithOptions(_:)),
            #selector(CoreAnimationSPI.contextWithCGSConnection(_:options:)), #selector(CoreAnimationSPI.localContext),
            #selector(CoreAnimationSPI.allContexts), #selector(CoreAnimationSPI.currentContext),
            #selector(CoreAnimationSPI.addCommitHandler(_:forPhase:)), #selector(CoreAnimationSPI.activate),
            #selector(CoreAnimationSPI.synchronize), #selector(CoreAnimationSPI.context),
            #selector(CoreAnimationSPI.setContextId(_:)), #selector(CoreAnimationSPI._layerContext),
        ]
        return Dictionary(list.map { (NSStringFromSelector($0), $0) }, uniquingKeysWith: { first, _ in first })
    }()

    static func object(_ target: NSObject, _ name: String) -> NSObject? {
        let selector = CoreAnimationFence.selector(name)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    static func instanceFunction<F>(_ target: NSObject, _ name: String, as _: F.Type) -> F? {
        let selector = CoreAnimationFence.selector(name)
        guard let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: F.self)
    }
}

/// SPIKE: one parseable `FENCE-PROBE {json}` line on stderr (a DEV build's app.log), for the Tart OS matrix. `phase`
/// "launch" passes no layer (selectors only); "first_window" passes the first window's content layer: the main thread
/// puts a fence in its current transaction (no wait), and a plain thread joins it in its own transaction, commits and
/// releases the port, as the terminal's off-main present would. With no fence on this OS, `fallback` is true and
/// nothing else runs. The main thread never blocks: the join, the release and the write all happen off main.
public nonisolated struct CoreAnimationFenceLaunchProbe: Sendable {
    /// The line's `phase` field.
    public let phase: String

    public init(phase: String) {
        self.phase = phase
    }

    public func run(layer: CALayer?) {
        let phase = phase
        let found = CoreAnimationFence.probe(layer: layer)
        let fence = layer.flatMap { CoreAnimationFence(contextOf: $0) }
        let port = fence?.createFencePort()
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
        let hadLayer = layer != nil
        let flags: [String: Bool] = [
            "createFencePort": found["-[CAContext createFencePort]"] ?? false,
            "setFencePort": found["-[CAContext setFencePort:]"] ?? false,
            "invalidateFences": found["-[CAContext invalidateFences]"] ?? false,
            "remoteContext": found["+[CAContext remoteContextWithOptions:]"] ?? false,
            "layerHost": found["-[CALayerHost setContextId:]"] ?? false,
            "layer_context": found["layer.context non-nil"] ?? false,
            "fallback": hadLayer && fence == nil,
        ]
        let thread = Thread {
            var line: [String: Any] = flags
            line["phase"] = phase
            line["os"] = os
            if let fence, let port {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                fence.join(port)
                CATransaction.commit()
                CoreAnimationFence.release(port)
                line["fence_ok"] = true
            } else if !hadLayer {
                line["fence_ok"] = "not_tried"
            } else {
                line["fence_ok"] = fence == nil ? "fallback" : false
            }
            let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
            fputs("FENCE-PROBE \(String(decoding: data, as: UTF8.self))\n", stderr)
        }
        thread.name = "cmux.spike.fence-probe"
        thread.start()
    }
}

/// SPIKE: a layer tree in its own CAContext, shown in a window's tree through a `CALayerHost`, as WebKit's and
/// Chromium's remote layers are, in one process. A fence made from ``fence`` holds only this context's commits.
/// nil when this OS lacks a selector or class.
// crash-allow: immutable after init; the layers and the CAContext are only read, and CA locks its own state.
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
        let remote = CoreAnimationFence.selector("remoteContextWithOptions:")
        if let method = class_getClassMethod(contextClass, remote) {
            let function = unsafeBitCast(method_getImplementation(method), to: RemoteFunction.self)
            made = function(contextClass as AnyObject, remote, NSDictionary())?.takeUnretainedValue()
        }
        let cgs = CoreAnimationFence.selector("contextWithCGSConnection:options:")
        if made == nil, let method = class_getClassMethod(contextClass, cgs),
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") {
            let connection = unsafeBitCast(symbol, to: MainConnection.self)()
            let function = unsafeBitCast(method_getImplementation(method), to: CGSFunction.self)
            made = function(contextClass as AnyObject, cgs, connection, NSDictionary())?.takeUnretainedValue()
        }
        guard let context = made,
              let fence = CoreAnimationFence(context: context),
              let contextId = CoreAnimationFence.instanceFunction(context, "contextId", as: ContextIdFunction.self)
        else { return nil }
        let setLayer = CoreAnimationFence.selector("setLayer:")
        guard context.responds(to: setLayer) else { return nil }
        context.perform(setLayer, with: root)
        let host = hostClass.init()
        let setContextId = CoreAnimationFence.selector("setContextId:")
        guard let setId = CoreAnimationFence.instanceFunction(host, "setContextId:", as: SetContextIdFunction.self) else { return nil }
        setId(host, setContextId, contextId(context, CoreAnimationFence.selector("contextId")))
        self.context = context
        self.fence = fence
        hostLayer = host
    }
}

/// The SPI selectors, declared once so `#selector` names them at compile time. Nothing conforms: it is only a table of
/// names (class methods are declared as instance methods: a selector is only a name); every call checks the receiver
/// has the method first (``CoreAnimationFence``).
@objc private protocol CoreAnimationSPI {
    func createFencePort() -> UInt32
    func setFencePort(_ port: UInt32)
    func setFencePort(_ port: UInt32, commitHandler: Any)
    func invalidateFences()
    func contextId() -> UInt32
    func setLayer(_ layer: CALayer?)
    func layer() -> CALayer?
    func invalidate()
    func remoteContextWithOptions(_ options: NSDictionary?) -> NSObject?
    func contextWithCGSConnection(_ connection: UInt32, options: NSDictionary?) -> NSObject?
    func localContext() -> NSObject?
    func allContexts() -> NSArray?
    func currentContext() -> NSObject?
    func addCommitHandler(_ handler: Any, forPhase phase: Int)
    func activate()
    func synchronize()
    func context() -> NSObject?
    func setContextId(_ contextId: UInt32)
    func _layerContext() -> NSObject?
}
