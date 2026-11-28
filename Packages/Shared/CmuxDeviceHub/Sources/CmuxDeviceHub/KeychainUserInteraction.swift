#if canImport(Security)
import Foundation
import os

/// Runs login (file-based) Keychain calls with the process's Keychain user interaction off, so a call
/// that would prompt answers `errSecInteractionNotAllowed` instead. An `LAContext` or
/// `kSecUseAuthenticationUI` does not stop the login Keychain's prompt; only this switch does.
///
/// The switch is the process's, so this guard is process-wide too: one static depth count, the last
/// one out restores it. CmuxDeviceHub and CmuxPhonePush each keep an internal copy,
/// and the cmux NEXT app uses its own `LoginKeychain`; a process that linked two of them would have
/// two counts, and one could turn the switch back on under the other's guard. On iOS there is no
/// login Keychain and `body` just runs.
enum KeychainUserInteraction {
    private struct State {
        var depth = 0
        var previous = true
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `body` with Keychain user interaction off.
    static func withoutUI<Result, E: Error>(_ body: () throws(E) -> Result) throws(E) -> Result {
        #if os(macOS)
        state.withLock { state in
            if state.depth == 0 {
                var allowed: UInt8 = 1
                if let get { _ = get(&allowed) }
                state.previous = allowed != 0
                _ = set?(0)
            }
            state.depth += 1
        }
        defer {
            state.withLock { state in
                state.depth -= 1
                if state.depth == 0 { _ = set?(state.previous ? 1 : 0) }
            }
        }
        #endif
        return try body()
    }

    #if os(macOS)
    // `SecKeychain{Get,Set}UserInteractionAllowed`, resolved at run time: the SDK marks them deprecated
    // (they still work and have no replacement for the login Keychain).
    private typealias Getter = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32
    private typealias Setter = @convention(c) (UInt8) -> Int32

    private static let get: Getter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainGetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: Getter.self) }
    private static let set: Setter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: Setter.self) }
    #endif
}
#endif
