import CoreGraphics
import Foundation
import ObjectiveC.runtime

// Calls into CoreSimulator and SimulatorKit, which have no headers. Every
// call checks that the object answers the selector first, so a changed Xcode
// turns a capability off instead of crashing (plans/cmux-next/simulators-DESIGN.md).
// Selector shapes are the ones classic cmux used (adapted there from
// serve-sim, Baguette and idb).
//
// Every send goes through `PrivateMethod.function(_:returns:arguments:)`, the
// module's one cast of an implementation to a function type. It casts only
// when the runtime's type encoding for that method has the return and
// argument kinds the caller's function type spells, so a selector whose shape
// changed is not called with the wrong registers (a scalar read as an object,
// a struct return read from x0).

/// The selector `name`. Every caller checks `responds(to:)` (or
/// `class_respondsToSelector`) before sending it, so an unknown selector
/// turns a capability off instead of raising.
func privateSelector(_ name: String) -> Selector {
    // crash-allow: the one dynamic selector lookup; each call site checks responds(to:) before any send.
    NSSelectorFromString(name)
}

/// A method an object (or a class) answers: its selector, its implementation
/// and its signature.
struct PrivateMethod {
    let selector: Selector
    let signature: PrivateSignature
    private let implementation: IMP

    private init(selector: Selector, signature: PrivateSignature, implementation: IMP) {
        self.selector = selector
        self.signature = signature
        // SAFETY: stores the function pointer only; `function(_:returns:arguments:)` casts it.
        unsafe self.implementation = implementation
    }

    /// The instance method `name` of `target`, its own or one it answers by
    /// forwarding; nil when `target` does not answer it or no signature for
    /// it can be read.
    init?(_ target: NSObject, _ name: String) {
        let selector = privateSelector(name)
        guard target.responds(to: selector),
              let found = Self.method(selector, of: type(of: target), classMethod: false)
                ?? Self.forwarded(selector, of: target) else { return nil }
        self = found
    }

    /// The instance method `name` of instances of `cls`, before there is one.
    /// `class_respondsToSelector` counts only methods `cls` has, so there is
    /// no forwarding to follow.
    init?(instanceMethod name: String, of cls: AnyClass) {
        let selector = privateSelector(name)
        guard class_respondsToSelector(cls, selector),
              let found = Self.method(selector, of: cls, classMethod: false) else { return nil }
        self = found
    }

    /// The class method `name` of `cls`.
    init?(classMethod name: String, of cls: AnyClass) {
        let selector = privateSelector(name)
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, selector),
              let found = Self.method(selector, of: cls, classMethod: true) else { return nil }
        self = found
    }

    /// The method `cls` itself has for `selector`, with the runtime's encoding of it.
    private static func method(_ selector: Selector, of cls: AnyClass, classMethod: Bool) -> PrivateMethod? {
        // SAFETY: a Method is the runtime's handle on one method of `cls`; method lists live as
        // long as their class, and a class is never unloaded once registered, so the handle and
        // the encoding it points to stay valid. Nothing here writes through it.
        guard let method = unsafe (classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)),
              // SAFETY: as above; the encoding is a NUL-terminated string the runtime keeps.
              let types = unsafe method_getTypeEncoding(method),
              // SAFETY: String(cString:) copies the NUL-terminated encoding during the call.
              let signature = PrivateSignature(encoding: unsafe String(cString: types)) else { return nil }
        // SAFETY: as above, the handle of a method of a loaded class.
        return unsafe PrivateMethod(selector: selector, signature: signature, implementation: method_getImplementation(method))
    }

    private typealias ObjectForSelector = @convention(c) (AnyObject, Selector, Selector) -> AnyObject?
    private typealias ArgumentCount = @convention(c) (AnyObject, Selector) -> UInt
    private typealias ReturnType = @convention(c) (AnyObject, Selector) -> UnsafePointer<CChar>?
    private typealias ArgumentType = @convention(c) (AnyObject, Selector, UInt) -> UnsafePointer<CChar>?

    /// A selector `target` answers by forwarding, so its class has no Method
    /// for it. Foundation forwards through `forwardingTargetForSelector:` or
    /// through `methodSignatureForSelector:` and `forwardInvocation:`; the
    /// signature comes from the same place, and the implementation is the
    /// runtime's forwarding entry (`_objc_msgForward`, what
    /// `class_getMethodImplementation` returns for such a selector), which
    /// passes the call's registers on unchanged. A structure return is refused:
    /// x86_64 forwards a large one through `_objc_msgForward_stret` instead.
    private static func forwarded(_ selector: Selector, of target: NSObject) -> PrivateMethod? {
        let receiver = forwardingTarget(selector, of: target) ?? target
        guard let signature = method(selector, of: type(of: receiver), classMethod: false)?.signature
                ?? messageSignature(selector, of: receiver) else { return nil }
        if case .structure = PrivateSignature.kind(of: signature.returns) { return nil }
        // SAFETY: the runtime's entry for `selector` on target's class, which lives as long as
        // the runtime; nothing here calls it.
        guard let forward = unsafe class_getMethodImplementation(type(of: target), selector) else { return nil }
        // SAFETY: stores the entry only; function(_:returns:arguments:) checks `signature` first.
        return unsafe PrivateMethod(selector: selector, signature: signature, implementation: forward)
    }

    /// The object `target` hands `selector` to (`forwardingTargetForSelector:`), if another.
    private static func forwardingTarget(_ selector: Selector, of target: NSObject) -> NSObject? {
        guard let asked = method(privateSelector("forwardingTargetForSelector:"), of: type(of: target), classMethod: false),
              let call = asked.function(ObjectForSelector.self, returns: .object, arguments: [.selector]),
              let other = call(target, asked.selector, selector) as? NSObject, other !== target else { return nil }
        return other
    }

    /// The signature `methodSignatureForSelector:` gives for `selector` on
    /// `target`, read from the NSMethodSignature's type strings (Swift does
    /// not import NSMethodSignature); nil when it gives none.
    static func messageSignature(_ selector: Selector, of target: NSObject) -> PrivateSignature? {
        guard let asked = method(privateSelector("methodSignatureForSelector:"), of: type(of: target), classMethod: false),
              let signatureFor = asked.function(ObjectForSelector.self, returns: .object, arguments: [.selector]),
              let described = signatureFor(target, asked.selector, selector) else { return nil }
        let cls: AnyClass = type(of: described)
        guard let countMethod = method(privateSelector("numberOfArguments"), of: cls, classMethod: false),
              let count = countMethod.function(ArgumentCount.self, returns: .integer(bytes: 8), arguments: []),
              let returnMethod = method(privateSelector("methodReturnType"), of: cls, classMethod: false),
              // SAFETY: only resolves the function; see the call below.
              let returnType = unsafe returnMethod.function(ReturnType.self, returns: .pointer, arguments: []),
              let argumentMethod = method(privateSelector("getArgumentTypeAtIndex:"), of: cls, classMethod: false),
              // SAFETY: only resolves the function; see the call below.
              let argumentType = unsafe argumentMethod.function(ArgumentType.self, returns: .pointer, arguments: [.integer(bytes: 8)])
        else { return nil }
        // SAFETY: the type is a NUL-terminated string that `described`, held here, owns;
        // String(cString:) copies it during the call.
        guard let returned = unsafe returnType(described, returnMethod.selector).map({ unsafe String(cString: $0) }) else { return nil }
        var encoding = returned
        for index in 0..<count(described, countMethod.selector) {
            // SAFETY: as above; `index` is below numberOfArguments, so the call does not raise.
            guard let argument = unsafe argumentType(described, argumentMethod.selector, index).map({ unsafe String(cString: $0) }) else {
                return nil
            }
            encoding += argument
        }
        return PrivateSignature(encoding: encoding)
    }

    /// The implementation called as `F`, a `@convention(c)` function type
    /// whose first two parameters are the receiver and the selector; nil
    /// unless the method returns `returns` and takes `arguments` (the kinds
    /// of F's remaining parameters), so a changed Xcode turns the capability
    /// off instead of being called with the wrong registers.
    func function<F>(_: F.Type, returns: PrivateSignature.Kind, arguments: [PrivateSignature.Kind]) -> F? {
        guard signature.matches(returns: returns, arguments: arguments) else { return nil }
        // SAFETY: an IMP is a C function pointer of the method's own signature (or the runtime's
        // forwarding entry, which passes the registers on unchanged to the method that has it),
        // and that signature has the return and argument kinds F spells (checked above; the
        // caller writes `returns` and `arguments` from F next to it), so every value F passes or
        // reads is where the implementation puts it. F and IMP are both one function pointer.
        return unsafe unsafeBitCast(implementation, to: F.self)
    }
}

private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> AnyObject?
private typealias Action = @convention(c) (AnyObject, Selector) -> Void
private typealias ObjectAction = @convention(c) (AnyObject, Selector, AnyObject) -> Void

/// The object-returning property `name` of `target`, resolved once so a
/// per-frame read keeps it; nil when `target` does not answer it with an object.
func privateGetter(_ target: NSObject, _ name: String) -> (() -> NSObject?)? {
    guard let method = PrivateMethod(target, name),
          let get = method.function(ObjectGetter.self, returns: .object, arguments: []) else { return nil }
    let selector = method.selector
    // A getter's result is +0, as the C convention of `ObjectGetter` reads it.
    return { get(target, selector) as? NSObject }
}

/// An object-returning property, or nil when the object does not answer it.
func privateObject(_ target: NSObject, _ name: String) -> NSObject? {
    privateGetter(target, name)?()
}

private typealias DoubleGetter = @convention(c) (AnyObject, Selector) -> Double
private typealias FloatGetter = @convention(c) (AnyObject, Selector) -> Float
private typealias Int64Getter = @convention(c) (AnyObject, Selector) -> Int64
private typealias UInt64Getter = @convention(c) (AnyObject, Selector) -> UInt64
private typealias Int32Getter = @convention(c) (AnyObject, Selector) -> Int32
private typealias UInt32Getter = @convention(c) (AnyObject, Selector) -> UInt32
private typealias Int16Getter = @convention(c) (AnyObject, Selector) -> Int16
private typealias UInt16Getter = @convention(c) (AnyObject, Selector) -> UInt16
private typealias Int8Getter = @convention(c) (AnyObject, Selector) -> Int8
private typealias UInt8Getter = @convention(c) (AnyObject, Selector) -> UInt8

/// A numeric property of any C scalar type, read through its type encoding.
func privateNumber(_ target: NSObject, _ name: String) -> Double? {
    guard let method = PrivateMethod(target, name) else { return nil }
    let s = method.selector
    switch method.signature.returns {
    case "d": return method.function(DoubleGetter.self, returns: .double, arguments: []).map { $0(target, s) }
    case "f": return method.function(FloatGetter.self, returns: .float, arguments: []).map { Double($0(target, s)) }
    case "q": return method.function(Int64Getter.self, returns: .integer(bytes: 8), arguments: []).map { Double($0(target, s)) }
    case "Q": return method.function(UInt64Getter.self, returns: .integer(bytes: 8), arguments: []).map { Double($0(target, s)) }
    case "i", "l": return method.function(Int32Getter.self, returns: .integer(bytes: 4), arguments: []).map { Double($0(target, s)) }
    case "I", "L": return method.function(UInt32Getter.self, returns: .integer(bytes: 4), arguments: []).map { Double($0(target, s)) }
    case "s": return method.function(Int16Getter.self, returns: .integer(bytes: 2), arguments: []).map { Double($0(target, s)) }
    case "S": return method.function(UInt16Getter.self, returns: .integer(bytes: 2), arguments: []).map { Double($0(target, s)) }
    case "c": return method.function(Int8Getter.self, returns: .integer(bytes: 1), arguments: []).map { Double($0(target, s)) }
    case "B", "C": return method.function(UInt8Getter.self, returns: .integer(bytes: 1), arguments: []).map { Double($0(target, s)) }
    default: return nil
    }
}

private typealias SizeGetter = @convention(c) (AnyObject, Selector) -> CGSize

/// A CGSize property (`SimDeviceType.mainScreenSize`), checked by its encoding.
func privateSize(_ target: NSObject, _ name: String) -> CGSize? {
    guard let method = PrivateMethod(target, name),
          let get = method.function(SizeGetter.self, returns: .structure("CGSize"), arguments: []) else { return nil }
    return get(target, method.selector)
}

private typealias ObjectWithError = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
private typealias ClassObjectWithError = @convention(c) (AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
private typealias InitWithError = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
private typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?

/// `-[target selector:&error]` returning an object.
func privateObjectWithError(_ target: NSObject, _ name: String) -> NSObject? {
    guard let method = PrivateMethod(target, name),
          // SAFETY: only resolves the function; see the call below.
          let call = unsafe method.function(ObjectWithError.self, returns: .object, arguments: [.pointer]) else { return nil }
    var error: NSError?
    // SAFETY: `error` is a local that outlives the call; the method stores at most one
    // autoreleased NSError in it (Cocoa's error convention). The result is +0.
    return unsafe call(target, method.selector, &error) as? NSObject
}

/// `+[cls selector:argument error:&error]` returning an object.
func privateClassObjectWithError(_ cls: AnyClass, _ name: String, _ argument: AnyObject) -> NSObject? {
    guard let method = PrivateMethod(classMethod: name, of: cls),
          // SAFETY: only resolves the function; see the call below.
          let call = unsafe method.function(ClassObjectWithError.self, returns: .object, arguments: [.object, .pointer]) else {
        return nil
    }
    var error: NSError?
    // SAFETY: as privateObjectWithError: `error` is a local that outlives the call. The result is +0.
    return unsafe call(cls, method.selector, argument, &error) as? NSObject
}

/// `[[cls alloc] initializer:argument error:&error]`: a new instance, or nil.
func privateInstance(of cls: NSObject.Type, initializer name: String, _ argument: AnyObject) -> NSObject? {
    // The initializer is checked before anything is allocated, so a missing one leaks nothing.
    guard let method = PrivateMethod(instanceMethod: name, of: cls),
          // SAFETY: only resolves the function; see the call below.
          let initialize = unsafe method.function(InitWithError.self, returns: .object, arguments: [.object, .pointer]),
          let allocMethod = PrivateMethod(classMethod: "alloc", of: cls),
          let alloc = allocMethod.function(Alloc.self, returns: .object, arguments: []),
          let instance = alloc(cls, allocMethod.selector) else { return nil }
    var error: NSError?
    // SAFETY: the object holds alloc's +1, which init consumes (ns_consumes_self) and replaces
    // with a +1 result (or nil), taken exactly once by takeRetainedValue. `error` is a local
    // that outlives the call.
    return unsafe initialize(instance, method.selector, argument, &error)?.takeRetainedValue() as? NSObject
}

/// `-[target name]` returning nothing, resolved once; nil when `target` does not answer it.
func privateAction(_ target: NSObject, _ name: String) -> (() -> Void)? {
    guard let method = PrivateMethod(target, name),
          let action = method.function(Action.self, returns: .void, arguments: []) else { return nil }
    let selector = method.selector
    return { action(target, selector) }
}

/// `-[target name]` returning nothing. False when `target` does not answer it.
@discardableResult
func privateVoid(_ target: NSObject, _ name: String) -> Bool {
    guard let action = privateAction(target, name) else { return false }
    action()
    return true
}

/// `-[target name:argument]` returning nothing. False when `target` does not answer it.
@discardableResult
func privateVoid(_ target: NSObject, _ name: String, _ argument: AnyObject) -> Bool {
    guard let method = PrivateMethod(target, name),
          let action = method.function(ObjectAction.self, returns: .void, arguments: [.object]) else { return false }
    action(target, method.selector, argument)
    return true
}
