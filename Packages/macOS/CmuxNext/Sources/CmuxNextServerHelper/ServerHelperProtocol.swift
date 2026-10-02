public import Foundation

/// The privileged helper's XPC interface (plans/cmux-next/server.md 9.4). The
/// helper is registered once with `SMAppService.daemon` (the user approves it
/// once in System Settings > Login Items) and serves only cmux processes signed
/// by the same team. Requests carry a fix id; anything else is refused.
@objc public protocol ServerHelperProtocol {
    /// Applies one allowlisted fix. Replies with nil on success, else a short reason.
    func apply(fixID: String, reply: @escaping @Sendable (String?) -> Void)
    /// Restores the macOS default for one allowlisted fix.
    func revert(fixID: String, reply: @escaping @Sendable (String?) -> Void)
    /// The helper's protocol version, so the app can replace an old helper.
    func version(reply: @escaping @Sendable (Int) -> Void)
}

public nonisolated enum ServerHelperConstants {
    public static let machServiceName = "com.cmux.server.helper"
    public static let plistName = "com.cmux.server.helper.plist"
    public static let protocolVersion = 1
}

/// The helper side: validates the fix id and runs exactly its argv.
public final nonisolated class ServerHelperService: NSObject, ServerHelperProtocol, @unchecked Sendable {
    private let runner: any ServerFixRunner

    public init(runner: any ServerFixRunner = ProcessFixRunner()) {
        self.runner = runner
    }

    public func apply(fixID: String, reply: @escaping @Sendable (String?) -> Void) {
        perform(fixID, revert: false, reply: reply)
    }

    public func revert(fixID: String, reply: @escaping @Sendable (String?) -> Void) {
        perform(fixID, revert: true, reply: reply)
    }

    public func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(ServerHelperConstants.protocolVersion)
    }

    private func perform(_ fixID: String, revert: Bool, reply: @escaping @Sendable (String?) -> Void) {
        guard let fix = ServerFix(rawValue: fixID) else {
            reply("unknown fix")
            return
        }
        let runner = runner
        let arguments = revert ? fix.revertArguments : fix.applyArguments
        Task {
            do {
                let status = try await runner.run(ServerFix.pmset, arguments)
                reply(status == 0 ? nil : "pmset exited \(status)")
            } catch {
                reply("pmset did not start")
            }
        }
    }
}
