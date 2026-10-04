import CmuxNextServerHelper
import Foundation
import ServiceManagement

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

    private static var service: SMAppService { SMAppService.daemon(plistName: ServerHelperConstants().plistName) }

    static var isBundled: Bool {
        let bundle = Bundle.main.bundleURL
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: bundle.appending(path: "Contents/Library/LaunchDaemons/\(ServerHelperConstants().plistName)").path)
            && fileManager.isExecutableFile(atPath: bundle.appending(path: ServerHelperConstants().bundleProgram).path)
    }

    /// Registers the helper. Idempotent: an enabled helper stays enabled. Call it
    /// from an explicit user action only: it may open System Settings.
    static func register() throws(Failure) {
        guard isBundled else { throw .notInBuild }
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw .requiresApproval
        default:
            do {
                try service.register()
            } catch {
                throw .failed(String(describing: error))
            }
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw .requiresApproval
            }
        }
    }

    /// Applies (or reverts) one allowlisted fix through the helper, after registering it.
    static func run(_ fix: ServerFix, revert: Bool = false) async throws(Failure) {
        // Check our own signature first: an ad hoc app must not register a root
        // daemon that can never serve it.
        guard let bundleID = Bundle.main.bundleIdentifier,
              let label = ServerHelperConstants().machServiceName(appBundleID: bundleID),
              let requirement = ServerHelperConstants().helperRequirement(teamID: ServerHelperListener.ownTeamIdentifier())
        else { throw .unsigned }
        try register()
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
        return try await ServerHelperDeadline().run(limit: replyLimit, clock: clock, operation: {
            try await connection.send(fixID: fixID, revert: revert)
        }, onTimeout: {
            // Invalidation fires the proxy's error handler, which ends the call.
            connection.invalidate()
        })
    }
}

/// The privileged connection to this build's helper.
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.fail($0) }
            guard let helper = proxy as? any ServerHelperProtocol else {
                once.fail(CocoaError(.featureUnsupported))
                return
            }
            let reply: @Sendable (String?) -> Void = { once.succeed($0) }
            if revert {
                helper.revert(fixID: fixID, reply: reply)
            } else {
                helper.apply(fixID: fixID, reply: reply)
            }
        }
    }
}

/// Resumes a continuation once: XPC may call both the reply and the error handler.
private final nonisolated class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock() // concurrency-allow: guards one optional swap, never held across an await or IO
    private var continuation: CheckedContinuation<String?, any Error>?

    init(_ continuation: CheckedContinuation<String?, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: String?) { take()?.resume(returning: value) }
    func fail(_ error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<String?, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
