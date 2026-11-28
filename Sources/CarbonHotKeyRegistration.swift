import Foundation

/// A Carbon hot key's key code and modifier mask, as registered with the system.
struct CarbonHotKeyRegistration: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
}
