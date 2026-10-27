// The main run loop's CoreFoundation description, which ``CommitBoundaryAudit`` reads its observers from. Darwin
// bridges the `CFString` with `as String`. swift-corelibs-foundation returns it optional and has no such bridge,
// but its CFString and NSString are toll-free bridged as on Darwin.

import CoreFoundation
import Foundation

extension CommitBoundaryAudit {
    /// `CFCopyDescription` of the main run loop: its modes and each mode's observers.
    static func mainRunLoopDescription() -> String {
        #if canImport(Darwin)
        CFCopyDescription(CFRunLoopGetMain()) as String
        #else
        CFCopyDescription(CFRunLoopGetMain()).map { unsafe unsafeBitCast($0, to: NSString.self) as String } ?? ""
        #endif
    }
}
