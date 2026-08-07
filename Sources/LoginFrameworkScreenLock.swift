import Darwin
import Foundation

/// In-process macOS login lock via `SACLockScreenImmediate` in
/// `login.framework` — the same call behind the Apple menu's "Lock Screen"
/// (⌃⌘Q). This replaces shelling out to the `CGSession` binary, which macOS 26
/// removed together with `User.menu`
/// (https://github.com/manaflow-ai/cmux/issues/9730); the framework call
/// predates the macOS 14 deployment floor. The symbol is resolved with
/// `dlsym` (the same pattern `SystemCommandRunner` uses for
/// `AuthorizationExecuteWithPrivileges`), so no private symbol is linked and a
/// macOS that drops it degrades to a reported failure, not a crash.
enum LoginFrameworkScreenLock {
    private typealias LockScreenFn = @convention(c) () -> Int32

    private static let lockScreenImmediate: LockScreenFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFn.self)
    }()

    /// Whether the lock call resolved in this process. Covered by a CI canary
    /// test so a future macOS removing the symbol turns CI red instead of
    /// silently breaking the Lock Mac button again.
    static var isAvailable: Bool { lockScreenImmediate != nil }

    /// Engages the login lock. Returns false only when the symbol is
    /// unavailable; the call's return code is not a documented contract, so a
    /// resolved symbol that was invoked counts as engaged.
    static func lockNow() -> Bool {
        guard let lockScreenImmediate else { return false }
        _ = lockScreenImmediate()
        return true
    }
}
