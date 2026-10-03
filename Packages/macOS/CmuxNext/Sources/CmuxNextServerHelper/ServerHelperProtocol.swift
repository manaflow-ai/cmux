public import Foundation

/// The privileged helper's XPC interface (plans/cmux-next/server.md 9.4). The
/// helper is registered once with `SMAppService.daemon` (the user approves it
/// once in System Settings > Login Items) and serves only the app bundle that
/// carries it, signed by the same team. Requests carry a fix id; anything else
/// is refused.
@objc public protocol ServerHelperProtocol {
    /// Applies one allowlisted fix. Replies with nil on success, else a short reason.
    func apply(fixID: String, reply: @escaping @Sendable (String?) -> Void)
    /// Restores the macOS default for one allowlisted fix.
    func revert(fixID: String, reply: @escaping @Sendable (String?) -> Void)
    /// The helper's protocol version, so the app can replace an old helper.
    func version(reply: @escaping @Sendable (Int) -> Void)
}

public nonisolated enum ServerHelperConstants {
    /// The LaunchDaemon plist in `Contents/Library/LaunchDaemons` of the app.
    public static let plistName = "com.cmux.server.helper.plist"
    /// The helper executable inside the app bundle (signed with the other
    /// `libexec` helpers by scripts/sign-cmux-bundle.sh).
    public static let bundleProgram = "Contents/Resources/libexec/cmux-server-helper"
    public static let protocolVersion = 1

    /// The launchd label and Mach service of the helper that `appBundleID`
    /// carries. Each tagged build has its own, so two builds never share a
    /// helper. Nil when the bundle id is not a plain reverse-DNS name.
    public static func machServiceName(appBundleID: String) -> String? {
        isPlainIdentifier(appBundleID) ? appBundleID + ".server-helper" : nil
    }

    /// Letters, digits, dots and hyphens only, so the value can sit inside a
    /// code-signing requirement string without quoting tricks.
    public static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 155 && !value.hasPrefix(".") && !value.hasSuffix(".")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    static func isPlainTeam(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The requirement the helper puts on its client: the exact app bundle
    /// that carries it, signed by the helper's own team. Nil without a team
    /// (an unsigned or ad hoc helper accepts nobody).
    public static func clientRequirement(teamID: String?, appBundleID: String) -> String? {
        guard let teamID, isPlainTeam(teamID), isPlainIdentifier(appBundleID) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(appBundleID)\""
    }

    /// The code-signing identifier of the helper executable. codesign derives
    /// it from the file name, so the build phase and scripts/sign-cmux-bundle.sh
    /// produce the same value.
    public static let helperIdentifier = "cmux-server-helper"

    /// The requirement the app puts on the helper it connects to: the helper
    /// executable signed by the app's own team. The per-build Mach service
    /// name keeps builds apart.
    public static func helperRequirement(teamID: String?) -> String? {
        guard let teamID, isPlainTeam(teamID) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(helperIdentifier)\""
    }
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
