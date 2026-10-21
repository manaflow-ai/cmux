import CoreGraphics
import Foundation
import ObjectiveC.runtime

// Calls into CoreSimulator and SimulatorKit, which have no headers. Every
// call checks that the object answers the selector first, so a changed Xcode
// turns a capability off instead of crashing (plans/cmux-next/simulators-DESIGN.md).
// Selector shapes are the ones classic cmux used (adapted there from
// serve-sim, Baguette and idb).

/// The selector `name`. Every caller checks `responds(to:)` (or
/// `class_respondsToSelector`) before sending it, so an unknown selector
/// turns a capability off instead of raising.
func privateSelector(_ name: String) -> Selector {
    // crash-allow: the one dynamic selector lookup; each call site checks responds(to:) before any send.
    NSSelectorFromString(name)
}

/// An object-returning property, or nil when the object does not answer it.
func privateObject(_ target: NSObject, _ name: String) -> NSObject? {
    let selector = privateSelector(name)
    guard target.responds(to: selector), let imp = class_getMethodImplementation(type(of: target), selector) else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(imp, to: Function.self)(target, selector)?.takeUnretainedValue() as? NSObject
}

/// A numeric property of any C scalar type, read through its type encoding.
func privateNumber(_ target: NSObject, _ name: String) -> Double? {
    let selector = privateSelector(name)
    guard target.responds(to: selector), let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
    let imp = method_getImplementation(method)
    let encoded = method_copyReturnType(method)
    defer { free(encoded) }
    let code = String(cString: encoded).drop(while: { "rnNoORV".contains($0) }).first
    switch code {
    case "d": typealias F = @convention(c) (AnyObject, Selector) -> Double; return unsafeBitCast(imp, to: F.self)(target, selector)
    case "f": typealias F = @convention(c) (AnyObject, Selector) -> Float; return Double(unsafeBitCast(imp, to: F.self)(target, selector))
    case "q", "l": typealias F = @convention(c) (AnyObject, Selector) -> Int64; return Double(unsafeBitCast(imp, to: F.self)(target, selector))
    case "Q", "L": typealias F = @convention(c) (AnyObject, Selector) -> UInt64; return Double(unsafeBitCast(imp, to: F.self)(target, selector))
    case "i": typealias F = @convention(c) (AnyObject, Selector) -> Int32; return Double(unsafeBitCast(imp, to: F.self)(target, selector))
    case "I": typealias F = @convention(c) (AnyObject, Selector) -> UInt32; return Double(unsafeBitCast(imp, to: F.self)(target, selector))
    case "B", "c", "C": typealias F = @convention(c) (AnyObject, Selector) -> UInt8; return Double(unsafeBitCast(imp, to: F.self)(target, selector))
    default: return nil
    }
}

/// A CGSize property (`SimDeviceType.mainScreenSize`), checked by its encoding.
func privateSize(_ target: NSObject, _ name: String) -> CGSize? {
    let selector = privateSelector(name)
    guard target.responds(to: selector), let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
    let encoded = method_copyReturnType(method)
    defer { free(encoded) }
    guard String(cString: encoded).hasPrefix("{CGSize=") else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> CGSize
    return unsafeBitCast(method_getImplementation(method), to: Function.self)(target, selector)
}

/// `-[target selector:&error]` returning an object.
func privateObjectWithError(_ target: NSObject, _ name: String) -> NSObject? {
    let selector = privateSelector(name)
    guard target.responds(to: selector), let imp = class_getMethodImplementation(type(of: target), selector) else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
    var error: NSError?
    return unsafeBitCast(imp, to: Function.self)(target, selector, &error)?.takeUnretainedValue() as? NSObject
}

/// `-[target selector]` returning nothing.
func privateVoid(_ target: NSObject, _ name: String) {
    let selector = privateSelector(name)
    guard target.responds(to: selector), let imp = class_getMethodImplementation(type(of: target), selector) else { return }
    typealias Function = @convention(c) (AnyObject, Selector) -> Void
    unsafeBitCast(imp, to: Function.self)(target, selector)
}
