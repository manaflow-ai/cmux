internal import CmuxThreading
internal import Foundation
public import Security

/// This process's code-signing team, read from its own signature: the one read the app's
/// `SigningTeamInstall` (CmuxNextCompat, which keeps it in memory after a lane loads it) and the privileged
/// server helper (which reads it once at start, before it serves anyone) share.
///
/// Each of its three Security calls asks the kernel and securityd and blocks, so each runs through the
/// `blockingCall` it was given: the app passes CmuxNextCompat's checked seam (the blocking detector sees each
/// call); the helper, which has no detector, takes the default, CmuxThreading's `blockingCall`.
///
/// ```swift
/// let team = RunningCodeSigningTeam().read()   // nil when ad hoc or unsigned
/// ```
public nonisolated struct RunningCodeSigningTeam: Sendable {
    private let call: @Sendable (_ body: () -> OSStatus) -> OSStatus

    /// A reader whose Security calls run through CmuxThreading's `blockingCall(.systemCall)` (the helper).
    public init() {
        call = { body in CmuxThreading.blockingCall(.systemCall, body) }
    }

    /// - Parameter blockingCall: Runs one Security call as a checked blocking call and returns its status.
    public init(blockingCall: @escaping @Sendable (_ body: () -> OSStatus) -> OSStatus) {
        call = blockingCall
    }

    /// Reads the running code's team from its signature: nil for an ad-hoc or unsigned build. It blocks: call
    /// it off the main thread of the app (the system lane), or where nothing waits (the helper's start).
    public func read() -> String? {
        var code: SecCode?
        // SAFETY: SecCodeCopySelf writes one retained SecCode reference into `code`, a local optional that outlives
        // the call.
        // blocking-allow: `call` runs it as the caller's checked blocking call (blockingCall(.systemCall)).
        guard call({ unsafe SecCodeCopySelf([], &code) }) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        // SAFETY: SecCodeCopyStaticCode writes one retained SecStaticCode reference into `staticCode`, a local
        // optional that outlives the call.
        // blocking-allow: `call` runs it as the caller's checked blocking call (blockingCall(.systemCall)).
        guard call({ unsafe SecCodeCopyStaticCode(code, [], &staticCode) }) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        // SAFETY: SecCodeCopySigningInformation writes one retained CFDictionary reference into `info`, a local
        // optional that outlives the call.
        // blocking-allow: `call` runs it as the caller's checked blocking call (blockingCall(.systemCall)).
        guard call({ unsafe SecCodeCopySigningInformation(staticCode, flags, &info) }) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }
}
