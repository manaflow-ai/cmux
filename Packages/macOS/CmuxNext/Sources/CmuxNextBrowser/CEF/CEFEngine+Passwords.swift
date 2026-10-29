import CmuxNextCompat
public import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

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
            try await startRuntime(trigger: "passwords")
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
            shim.passwordRemove(path, ids, id)
        }
        return Int(reply.value)
    }

    public func removePasswordException(_ exceptionID: String, in profile: BrowserProfileID) async throws -> Int {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password exception remove",
                                                             timeout: Self.passwordCoreTimeout) { path, id in
            shim.passwordExceptionRemove(path, exceptionID, id)
        }
        return Int(reply.value)
    }

    public func setPasswordUsername(_ username: String, id passwordID: String, in profile: BrowserProfileID) async throws -> Int {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password username", timeout: Self.passwordCoreTimeout) { path, id in
            shim.passwordSetUsername(path, passwordID, username, id)
        }
        return Int(reply.value)
    }

    /// Calls `copy` once with the password bytes, valid only during the call (the shim zeroes its
    /// buffer after it). False when the fork found no such sign-in, or when the Chromium Host
    /// exited first. The same call in both backends: in host mode the remote shim keeps the
    /// callback and runs it on main with the host's REPLY (remote_shim_local.mm).
    public func revealPassword(_ passwordID: String, in profile: BrowserProfileID,
                               copy: @escaping (UnsafeRawBufferPointer) -> Void) async throws -> Bool {
        let shim = try await coreShim()
        let path = CEFRuntime.shared.profileCachePath(profile)
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<Bool, any Error>) in
            // SAFETY: the box keeps `copy` and calls it only with the reveal callback's live buffer (`finish`).
            let box = unsafe PasswordRevealBox(copy: copy, continuation: continuation)
            // SAFETY: the +1 retain is the reveal's context: the callback takes it back once
            // (PasswordRevealBox.take), or the release below does when the shim did not start the reveal.
            let context = unsafe Unmanaged.passRetained(box).toOpaque()
            // SAFETY: the shim calls cefPasswordRevealCallback with `context` at most once, only after it returned 1.
            let started = unsafe shim.passwordReveal(path, passwordID, cefPasswordRevealCallback, context)
            if started != 1 {
                // SAFETY: no callback comes for a reveal that did not start; this drops the +1 once.
                unsafe Unmanaged<PasswordRevealBox>.fromOpaque(context).release()
                continuation.resume(throwing: BrowserTabError.closed)
            }
        }
    }

    public func exportPasswords(in profile: BrowserProfileID, to url: URL) async throws -> Int {
        let shim = try await coreShim()
        let reply = try await CEFRuntime.shared.profileWrite(profile, label: "password export", timeout: Self.passwordCoreTimeout) { path, id in
            shim.passwordExport(path, url.path, id)
        }
        return Int(reply.value)
    }

    private func coreShim() async throws -> CEFShimLibrary {
        try await startRuntime(trigger: "passwords")
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
}

/// C entry for a revealed password (cmux_shim_password_reveal). The bytes are valid only during
/// this call, so they are copied here or not at all.
let cefPasswordRevealCallback: CEFShimLibrary.PasswordRevealCallback = { context, bytes, length in
    // SAFETY: only the context's address is read here; PasswordRevealBox.take turns it back into the box.
    let address = unsafe UInt(bitPattern: context)
    guard address != 0 else { return }
    // The shim calls back on the main thread: CEF's UI thread in process, the event batch in host
    // mode. Off it, the password is dropped (never copied to another thread) and the reveal ends
    // as not found.
    guard Thread.isMainThread else {
        return MainRunLoopBlock.perform { PasswordRevealBox.take(address)?.finish(nil) }
    }
    // Integers cross into the main-actor closure (a raw buffer is not Sendable); the closure runs
    // synchronously, while the bytes are still valid.
    // SAFETY: only the bytes' address is read here; the buffer below is made from it during this call.
    let base = unsafe UInt(bitPattern: bytes)
    // main-proof: guarded by Thread.isMainThread above
    MainActor.assumeIsolated {
        // SAFETY: the shim's buffer holds `length` bytes until this callback returns, and the main-actor
        // closure runs synchronously within it; `finish` copies the bytes or drops them before it returns.
        let bytes = unsafe UnsafeRawPointer(bitPattern: base).map {
            unsafe PasswordRevealBytes(buffer: UnsafeRawBufferPointer(start: $0, count: max(length, 0)))
        }
        PasswordRevealBox.take(address)?.finish(bytes)
    }
}

/// One reveal in flight: the caller's copy closure and its continuation, resumed once.
@safe
final class PasswordRevealBox {
    private let copy: (UnsafeRawBufferPointer) -> Void
    private var continuation: OnceContinuation<Bool, any Error>?

    init(copy: @escaping (UnsafeRawBufferPointer) -> Void, continuation: OnceContinuation<Bool, any Error>) {
        // SAFETY: the box only keeps the closure; `finish` calls it with a buffer valid for that call.
        unsafe self.copy = copy
        self.continuation = continuation
    }

    /// The box the shim context names, taking back the retain the call gave it.
    /// The address is the box retained by revealPassword, passed back once by the shim; a null
    /// address (no box) is nil rather than a trap.
    static func take(_ address: UInt) -> PasswordRevealBox? {
        // SAFETY: a nonzero address is the box revealPassword retained, which the shim passes back once.
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: address) else { return nil }
        // SAFETY: as above; this takes back the +1 exactly once.
        return unsafe Unmanaged<PasswordRevealBox>.fromOpaque(pointer).takeRetainedValue()
    }

    /// `bytes` is valid only during this call (the reveal callback's buffer); nil: not found.
    func finish(_ bytes: PasswordRevealBytes?) {
        let count = bytes?.count ?? 0
        // SAFETY: the bytes are valid for this call (PasswordRevealBytes); `copy` reads them before it returns.
        if count > 0, let bytes { unsafe copy(bytes.buffer) }
        continuation?.resume(returning: count > 0)
        continuation = nil
    }
}

/// A revealed password's bytes in the shim's buffer, valid only while the reveal callback runs
/// (`cefPasswordRevealCallback`, which makes one and hands it to ``PasswordRevealBox/finish(_:)`` within the call).
@safe
struct PasswordRevealBytes {
    let buffer: UnsafeRawBufferPointer

    var count: Int { unsafe buffer.count }
}
