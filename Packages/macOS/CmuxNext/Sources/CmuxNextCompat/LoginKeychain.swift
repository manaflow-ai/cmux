internal import Darwin
// Links Security.framework, whose symbols are resolved below.
internal import Security

/// Calls into the login (file-based) Keychain that never show UI.
///
/// A login-Keychain item trusts the code signature that created it. When another signature reads
/// it (a rebuilt DEV app, an ad hoc rig build, another tag that shares the service), macOS asks
/// "cmux wants to use your confidential information stored in ... enter the login keychain
/// password". An `LAContext` with `interactionNotAllowed` or `kSecUseAuthenticationUI` does not stop
/// that prompt: the login Keychain's `SecItemCopyMatching` path reads neither (they only govern the
/// data-protection Keychain and access-control items). Only turning the process's Keychain user
/// interaction off does, and then the call answers `errSecInteractionNotAllowed` instead.
///
/// `withoutUI` turns it off for `body` and back to what it was after. The switch is the process's,
/// so another thread's Keychain call that overlaps `body` is also refused rather than prompting;
/// guarded calls are short reads and writes of cmux's own items, so the window is milliseconds.
/// Nested and concurrent guards share one switch: the last one out restores it. That count is this
/// instance's, so a process makes one: the composition root (`AppServices`) owns it and passes it to
/// every store that reads cmux's own items (a second instance would restore the switch under the
/// first one's guard).
///
/// Use it for items cmux itself creates and reads without the user asking (keys, salts, seals). Do
/// not use it where the prompt is the consent (reading another app's item on the user's request,
/// such as a browser's Safe Storage key during an import).
public final class LoginKeychain: Sendable {
    private struct State {
        var depth = 0
        var previous = true
    }

    private let state = Mutex(State())

    public init() {}

    /// Runs `body` with Keychain user interaction off.
    public func withoutUI<Result, E: Error>(_ body: () throws(E) -> Result) throws(E) -> Result {
        enter()
        defer { leave() }
        return try body()
    }

    /// Whether a Keychain call in this process may show UI now (false inside ``withoutUI(_:)``).
    public static var userInteractionAllowed: Bool {
        guard let get = Self.get else { return true }
        var allowed: UInt8 = 1
        _ = get(&allowed)
        return allowed != 0
    }

    private func enter() {
        state.withLock { state in
            if state.depth == 0 {
                state.previous = Self.userInteractionAllowed
                _ = Self.set?(0)
            }
            state.depth += 1
        }
    }

    private func leave() {
        state.withLock { state in
            state.depth -= 1
            if state.depth == 0 { _ = Self.set?(state.previous ? 1 : 0) }
        }
    }

    // `SecKeychain{Get,Set}UserInteractionAllowed`, resolved at run time: the SDK marks them
    // deprecated (they still work and have no replacement for the login Keychain), and a direct
    // call would add a deprecation warning to every build.
    private typealias Getter = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32
    private typealias Setter = @convention(c) (UInt8) -> Int32

    private static let get: Getter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainGetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: Getter.self) }
    private static let set: Setter? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: Setter.self) }
}
