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

/// A method's Objective-C type encoding (`method_getTypeEncoding`, Apple's
/// "Type Encodings"), without qualifiers and frame offsets: what it returns
/// and what each argument after `self` and `_cmd` is.
struct PrivateSignature: Equatable {
    /// How one value travels in a call: the property a function type and an
    /// implementation must agree on for the call to read what was passed.
    enum Kind: Equatable {
        case void
        /// An Objective-C object, class or block (`@`, `#`, `@?`).
        case object
        /// A C pointer (`^`, `*`).
        case pointer
        case selector
        /// An integer of this many bytes (`B c C s S i I l L q Q`; `l` and `L`
        /// are 32-bit in every Objective-C ABI, `long` is encoded `q`).
        case integer(bytes: Int)
        case float
        case double
        /// A C struct by its tag (`{CGSize=dd}` is `CGSize`).
        case structure(String)
        case other
    }

    /// The return type's code (`d`, `@`, `{CGSize=dd}`, ...).
    let returns: String
    /// The argument codes after `self` and `_cmd`.
    let arguments: [String]

    private static let qualifiers: Set<Character> = ["r", "n", "N", "o", "O", "R", "V", "A"]

    /// Parses a method type encoding such as `@24@0:8@16`; nil when it is
    /// not one (no `self` and `_cmd`, or a type that does not end).
    init?(encoding: String) {
        let codes = Array(encoding)
        var types: [String] = []
        var index = 0
        while index < codes.count {
            var start = index
            while start < codes.count, Self.qualifiers.contains(codes[start]) { start += 1 }
            guard let end = Self.typeEnd(codes, from: start) else { return nil }
            types.append(String(codes[start..<end]))
            index = end
            // The frame size after the return type, the offset after each argument.
            if index < codes.count, codes[index] == "-" { index += 1 }
            while index < codes.count, codes[index].isASCII, codes[index].isNumber { index += 1 }
        }
        guard types.count >= 3, Self.kind(of: types[1]) == .object, types[2] == ":" else { return nil }
        returns = types[0]
        arguments = Array(types[3...])
    }

    /// The index after the one type that starts at `start`.
    private static func typeEnd(_ codes: [Character], from start: Int) -> Int? {
        guard start < codes.count else { return nil }
        switch codes[start] {
        case "^":
            var pointee = start + 1
            while pointee < codes.count, qualifiers.contains(codes[pointee]) { pointee += 1 }
            return typeEnd(codes, from: pointee)
        case "@":
            var end = start + 1
            if end < codes.count, codes[end] == "?" {
                end += 1
                // An extended block signature: @?<v@?@>.
                if end < codes.count, codes[end] == "<" { return closing(codes, from: end, open: "<", close: ">") }
                return end
            }
            // An extended object type: @"NSString".
            if end < codes.count, codes[end] == "\"" {
                guard let quote = codes[(end + 1)...].firstIndex(of: "\"") else { return nil }
                end = quote + 1
            }
            return end
        case "{": return closing(codes, from: start, open: "{", close: "}")
        case "(": return closing(codes, from: start, open: "(", close: ")")
        case "[": return closing(codes, from: start, open: "[", close: "]")
        case "b":
            var end = start + 1
            while end < codes.count, codes[end].isASCII, codes[end].isNumber { end += 1 }
            return end
        default:
            return start + 1
        }
    }

    /// The index after the `close` that matches the `open` at `start`.
    private static func closing(_ codes: [Character], from start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        for index in start..<codes.count {
            if codes[index] == open { depth += 1 }
            if codes[index] == close {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
        }
        return nil
    }

    static func kind(of code: String) -> Kind {
        guard let first = code.first else { return .other }
        switch first {
        case "v": return .void
        case "@", "#": return .object
        case "^", "*": return .pointer
        case ":": return .selector
        case "B", "c", "C": return .integer(bytes: 1)
        case "s", "S": return .integer(bytes: 2)
        case "i", "I", "l", "L": return .integer(bytes: 4)
        case "q", "Q": return .integer(bytes: 8)
        case "f": return .float
        case "d": return .double
        case "{": return .structure(String(code.dropFirst().prefix { $0 != "=" && $0 != "}" }))
        default: return .other
        }
    }

    /// Whether `code` travels as `expected`. A Core Foundation reference
    /// (`^{__IOSurface=}`) is an object: CF types are Objective-C objects.
    static func matches(_ code: String, _ expected: Kind) -> Bool {
        kind(of: code) == expected || (expected == .object && code.hasPrefix("^{__"))
    }

    /// Whether the method returns `returns` and takes exactly `arguments` after `self` and `_cmd`.
    func matches(returns expected: Kind, arguments expectedArguments: [Kind]) -> Bool {
        Self.matches(returns, expected) && arguments.count == expectedArguments.count
            && zip(arguments, expectedArguments).allSatisfy { Self.matches($0, $1) }
    }
}

/// A method an object (or a class) answers: its selector, its implementation
/// and its signature.
struct PrivateMethod {
    let selector: Selector
    let signature: PrivateSignature
    private let implementation: IMP

    /// The instance method `name` of `target`; nil when `target` does not
    /// answer it or the runtime gives no readable encoding for it.
    init?(_ target: NSObject, _ name: String) {
        let selector = privateSelector(name)
        guard target.responds(to: selector) else { return nil }
        self.init(selector, of: type(of: target), classMethod: false)
    }

    /// The instance method `name` of instances of `cls`, before there is one.
    init?(instanceMethod name: String, of cls: AnyClass) {
        let selector = privateSelector(name)
        guard class_respondsToSelector(cls, selector) else { return nil }
        self.init(selector, of: cls, classMethod: false)
    }

    /// The class method `name` of `cls`.
    init?(classMethod name: String, of cls: AnyClass) {
        let selector = privateSelector(name)
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, selector) else { return nil }
        self.init(selector, of: cls, classMethod: true)
    }

    private init?(_ selector: Selector, of cls: AnyClass, classMethod: Bool) {
        // SAFETY: a Method is the runtime's handle on one method of `cls`; method lists live as
        // long as their class, and a class is never unloaded once registered, so the handle and
        // the encoding it points to stay valid. Nothing here writes through it.
        guard let method = unsafe (classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)),
              // SAFETY: as above; the encoding is a NUL-terminated string the runtime keeps.
              let types = unsafe method_getTypeEncoding(method),
              // SAFETY: String(cString:) copies the NUL-terminated encoding during the call.
              let signature = PrivateSignature(encoding: unsafe String(cString: types)) else { return nil }
        self.selector = selector
        self.signature = signature
        // SAFETY: as above, the handle of a method of a loaded class.
        implementation = unsafe method_getImplementation(method)
    }

    /// The implementation called as `F`, a `@convention(c)` function type
    /// whose first two parameters are the receiver and the selector; nil
    /// unless the method returns `returns` and takes `arguments` (the kinds
    /// of F's remaining parameters), so a changed Xcode turns the capability
    /// off instead of being called with the wrong registers.
    func function<F>(_: F.Type, returns: PrivateSignature.Kind, arguments: [PrivateSignature.Kind]) -> F? {
        guard signature.matches(returns: returns, arguments: arguments) else { return nil }
        // SAFETY: an IMP is a C function pointer of the method's own signature, and the runtime's
        // encoding of this method has the return and argument kinds F spells (checked above; the
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
