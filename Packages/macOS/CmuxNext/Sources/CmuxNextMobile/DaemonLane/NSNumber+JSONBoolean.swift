import Foundation

extension NSNumber {
    /// Whether this is a JSON `true` or `false` (a CFBoolean), not the number 0 or 1. corelibs Foundation
    /// (Linux) exposes no CFGetTypeID; its booleans are instances of the class `NSNumber(value: true)` is.
    var isJSONBoolean: Bool {
        #if canImport(Darwin)
        CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        ObjectIdentifier(type(of: self)) == ObjectIdentifier(type(of: NSNumber(value: true)))
        #endif
    }
}
