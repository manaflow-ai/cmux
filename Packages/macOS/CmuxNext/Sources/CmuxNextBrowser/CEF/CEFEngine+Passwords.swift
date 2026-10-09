public import Foundation

/// The Passwords page's saved sign-ins (plans/cmux-next/passwords.md 1.4): the fork's password
/// core (API 18: `cmux_password_list`, `_remove`, `_exception_remove`, `_set_username`,
/// `_reveal`, `_export`) through the shim. Each call starts Chromium when it is not running yet.
/// Results are the fork's codes: counts, -1 failed, -2 (username) taken.
extension CEFEngine {
    static let passwordCoreForkAPI: Int32 = 18
    static let passwordCoreTimeout: Duration = .seconds(30)

    /// Whether this build's Chromium has every password core call.
    public func canManagePasswords() async -> Bool {
        do {
            try await CEFRuntime.shared.start(layout: layout, trigger: "passwords")
        } catch {
            return false
        }
        return Self.passwordCoreShim() != nil
    }

    /// The saved sign-ins and never-save sites of `profile` (metadata only).
    public func passwordList(in profile: BrowserProfileID) async throws -> ChromiumPasswordList {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password list", timeout: Self.passwordCoreTimeout) { path, id in
            shim.passwordList(path, id)
        }
        guard reply.value == 1, let list = ChromiumPasswordList.parse(reply.json) else { throw ChromiumPasskeyError.keychainUnreadable }
        return list
    }

    public func removePasswords(_ ids: [String], in profile: BrowserProfileID) async throws -> Int {
        let shim = try await coreShim()
        guard !ids.isEmpty else { return 0 }
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password remove", timeout: Self.passwordCoreTimeout) { path, id in
            Self.withCStrings(ids) { pointers in shim.passwordRemove(path, pointers, Int32(ids.count), id) }
        }
        return Int(reply.value)
    }

    public func removePasswordException(_ exceptionID: String, in profile: BrowserProfileID) async throws -> Int {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password exception remove",
                                                             timeout: Self.passwordCoreTimeout) { path, id in
            exceptionID.withCString { shim.passwordExceptionRemove(path, $0, id) }
        }
        return Int(reply.value)
    }

    public func setPasswordUsername(_ username: String, id passwordID: String, in profile: BrowserProfileID) async throws -> Int {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password username", timeout: Self.passwordCoreTimeout) { path, id in
            passwordID.withCString { idText in username.withCString { shim.passwordSetUsername(path, idText, $0, id) } }
        }
        return Int(reply.value)
    }

    /// Calls `copy` once with the password bytes, valid only during the call (the shim zeroes its
    /// buffer after it). False when the fork found no such sign-in.
    public func revealPassword(_ passwordID: String, in profile: BrowserProfileID,
                               copy: @escaping (UnsafeRawBufferPointer) -> Void) async throws -> Bool {
        let shim = try await coreShim()
        let path = CEFRuntime.shared.profileCachePath(profile)
        return try await withCheckedThrowingContinuation { continuation in
            let box = PasswordRevealBox(copy: copy, continuation: continuation)
            let context = Unmanaged.passRetained(box).toOpaque()
            let started = path.withCString { pathText in
                passwordID.withCString { shim.passwordReveal(pathText, $0, cefPasswordRevealCallback, context) }
            }
            if started != 1 {
                Unmanaged<PasswordRevealBox>.fromOpaque(context).release()
                continuation.resume(throwing: BrowserTabError.closed)
            }
        }
    }

    public func exportPasswords(in profile: BrowserProfileID, to url: URL) async throws -> Int {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password export", timeout: Self.passwordCoreTimeout) { path, id in
            url.path.withCString { shim.passwordExport(path, $0, id) }
        }
        return Int(reply.value)
    }

    private func coreShim() async throws -> CEFShimLibrary {
        try await CEFRuntime.shared.start(layout: layout, trigger: "passwords")
        guard let shim = Self.passwordCoreShim() else { throw ChromiumPasskeyError.unavailable }
        return shim
    }

    /// The loaded shim when the running fork has every password core call (API 18), else nil.
    private static func passwordCoreShim() -> CEFShimLibrary? {
        let runtime = CEFRuntime.shared
        guard let shim = runtime.shim, runtime.state == .ready, runtime.forkAPIVersion >= passwordCoreForkAPI,
              shim.passwordCoreAvailable() == 1 else { return nil }
        return shim
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = strings.map { strdup($0) }
        let array = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: max(copies.count, 1))
        defer {
            array.deallocate()
            copies.forEach { free($0) }
        }
        for (index, copy) in copies.enumerated() { array[index] = UnsafePointer(copy) }
        return body(UnsafePointer(array))
    }
}

/// C entry for a revealed password (cmux_shim_password_reveal). The bytes are valid only during
/// this call, so they are copied here or not at all.
let cefPasswordRevealCallback: CEFShimLibrary.PasswordRevealCallback = { context, bytes, length in
    guard let context else { return }
    let address = UInt(bitPattern: context)
    // The shim calls back on the CEF UI thread, which is the main thread. Off it, the password is
    // dropped (never copied to another thread) and the reveal ends as not found.
    guard Thread.isMainThread else {
        // main-proof: a DispatchQueue.main block runs on the main thread
        DispatchQueue.main.async { MainActor.assumeIsolated { PasswordRevealBox.take(address).finish(nil) } }
        return
    }
    // Integers cross into the main-actor closure (a raw buffer is not Sendable); the closure runs
    // synchronously, while the bytes are still valid.
    let base = UInt(bitPattern: bytes)
    // main-proof: guarded by Thread.isMainThread above
    MainActor.assumeIsolated {
        let buffer = UnsafeRawPointer(bitPattern: base).map { UnsafeRawBufferPointer(start: $0, count: length) }
        PasswordRevealBox.take(address).finish(buffer)
    }
}

/// One reveal in flight: the caller's copy closure and its continuation, resumed once.
final class PasswordRevealBox {
    private let copy: (UnsafeRawBufferPointer) -> Void
    private var continuation: CheckedContinuation<Bool, any Error>?

    init(copy: @escaping (UnsafeRawBufferPointer) -> Void, continuation: CheckedContinuation<Bool, any Error>) {
        self.copy = copy
        self.continuation = continuation
    }

    /// The box the shim context names, taking back the retain the call gave it.
    static func take(_ address: UInt) -> PasswordRevealBox {
        // crash-allow: the address is the box retained by revealPassword, passed back once by the shim
        Unmanaged<PasswordRevealBox>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeRetainedValue()
    }

    func finish(_ bytes: UnsafeRawBufferPointer?) {
        if let bytes, bytes.count > 0 { copy(bytes) }
        continuation?.resume(returning: (bytes?.count ?? 0) > 0)
        continuation = nil
    }
}
