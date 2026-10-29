import CmuxNextCompat
import CmuxNextServerHelper
import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// The app side of the cmux server's privileged helper (plans/cmux-next/server.md 9.4).
/// The helper is a LaunchDaemon the app bundle carries in
/// `Contents/Library/LaunchDaemons/com.cmux.server.helper.plist`; the user approves it
/// once in System Settings > Login Items. Each build has its own label
/// (`<bundle id>.server-helper`), and the app talks only to a helper signed by its own team.
enum ServerHelperClient {
    enum Failure: Error, Equatable {
        /// This build does not carry the helper (stable builds, or a build without the phase).
        case notInBuild
        /// The app is unsigned or ad hoc, so no helper would accept it.
        case unsigned
        /// The user must allow the helper in System Settings > Login Items.
        case requiresApproval
        /// The helper refused or failed the fix; the reason is the helper's.
        case refused(String)
        /// The helper did not answer within `replyLimit`.
        case timedOut
        case failed(String)
    }

    static var isBundled: Bool {
        let bundle = Bundle.main.bundleURL
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: bundle.appending(path: "Contents/Library/LaunchDaemons/\(ServerHelperConstants().plistName)").path)
            && fileManager.isExecutableFile(atPath: bundle.appending(path: ServerHelperConstants().bundleProgram).path)
    }

    /// Applies (or reverts) one allowlisted fix through the helper, after registering it
    /// (`helper`'s launchd calls run on the system lane; it may open System Settings, so
    /// call it from an explicit user action only). `willCall` runs once the app is signed
    /// and the helper is registered and allowed, just before the request goes out (the fix
    /// ledger records there, so a build or helper that can never run writes nothing); if it
    /// throws, nothing is sent.
    static func run(_ fix: ServerFix, revert: Bool = false, helper: ServerServiceRegistration,
                    willCall: @MainActor () async throws -> Void = {}) async throws(Failure) {
        // Check our own signature first: an ad hoc app must not register a root
        // daemon that can never serve it.
        guard let bundleID = Bundle.main.bundleIdentifier,
              let label = ServerHelperConstants().machServiceName(appBundleID: bundleID),
              let requirement = ServerHelperConstants().helperRequirement(teamID: SigningTeamInstall.process.team)
        else { throw .unsigned }
        guard isBundled else { throw .notInBuild }
        try await helper.enable(requiresApproval: Failure.requiresApproval, failed: Failure.failed)
        do {
            try await willCall()
        } catch {
            throw .failed(String(describing: error))
        }
        let reason: String?
        do {
            reason = try await call(label: label, requirement: requirement, fixID: fix.rawValue, revert: revert)
        } catch is ServerHelperTimedOut {
            throw .timedOut
        } catch {
            throw .failed(String(describing: error))
        }
        if let reason { throw .refused(reason) }
    }

    /// The longest the app waits for the helper (pmset itself is bounded at 10 s).
    static let replyLimit: Duration = .seconds(30)

    /// One XPC request on a fresh privileged connection; the reply, the
    /// connection error or the deadline resumes the continuation exactly once.
    private static func call(label: String, requirement: String, fixID: String, revert: Bool,
                             clock: any Clock<Duration> = ContinuousClock()) async throws -> String? {
        let connection = HelperConnection(label: label, requirement: requirement)
        defer { connection.invalidate() }
        return try await ServerHelperDeadline().run(limit: replyLimit, tolerance: WakeLeeway.window(delay: replyLimit).tolerance,
                                                    clock: clock, operation: {
            try await connection.send(fixID: fixID, revert: revert)
        }, onTimeout: {
            // Invalidation fires the proxy's error handler, which ends the call.
            connection.invalidate()
        })
    }
}

/// The privileged connection to this build's helper.
// crash-allow: one immutable NSXPCConnection, configured and resumed in init; its proxy and invalidate calls are thread-safe.
private final nonisolated class HelperConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(label: String, requirement: String) {
        connection = NSXPCConnection(machServiceName: label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any ServerHelperProtocol).self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
    }

    func invalidate() { connection.invalidate() }

    func send(fixID: String, revert: Bool) async throws -> String? {
        // XPC may call both the reply and the error handler: the first resume wins.
        try await withOnceThrowingContinuation { (once: OnceContinuation<String?, any Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.resume(throwing: $0) }
            guard let helper = proxy as? any ServerHelperProtocol else {
                once.resume(throwing: CocoaError(.featureUnsupported))
                return
            }
            let reply: @Sendable (String?) -> Void = { once.resume(returning: $0) }
            if revert {
                helper.revert(fixID: fixID, reply: reply)
            } else {
                helper.apply(fixID: fixID, reply: reply)
            }
        }
    }
}
