public import Foundation

/// The privileged helper's XPC interface (plans/cmux-next/server.md 9.4). The
/// helper is registered once with `SMAppService.daemon` (the user approves it
/// once in System Settings > Login Items) and serves only the app bundle that
/// carries it, signed by the same team. Requests carry a fix id; anything else
/// is refused.
@objc public protocol ServerHelperProtocol {
    /// Applies one allowlisted fix. Replies with nil on success, else a short reason.
    func apply(fixID: String, reply: @escaping @Sendable (String?) -> Void)
    /// Restores the value the fix replaced (recorded at apply time).
    func revert(fixID: String, reply: @escaping @Sendable (String?) -> Void)
    /// The helper's protocol version, so the app can replace an old helper.
    func version(reply: @escaping @Sendable (Int) -> Void)
}

public struct ServerHelperConstants {
    public nonisolated init() {}
    /// The LaunchDaemon plist in `Contents/Library/LaunchDaemons` of the app.
    public nonisolated let plistName = "com.cmux.server.helper.plist"
    /// The helper executable inside the app bundle (signed with the other
    /// `libexec` helpers by scripts/sign-cmux-bundle.sh).
    public nonisolated let bundleProgram = "Contents/Resources/libexec/cmux-server-helper"
    public nonisolated let protocolVersion = 1

    /// The launchd label and Mach service of the helper that `appBundleID`
    /// carries. Each tagged build has its own, so two builds never share a
    /// helper. Nil when the bundle id is not a plain reverse-DNS name.
    public nonisolated func machServiceName(appBundleID: String) -> String? {
        isPlainIdentifier(appBundleID) ? appBundleID + ".server-helper" : nil
    }

    /// Letters, digits, dots and hyphens only, so the value can sit inside a
    /// code-signing requirement string without quoting tricks.
    public nonisolated func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 155 && !value.hasPrefix(".") && !value.hasSuffix(".")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    nonisolated func isPlainTeam(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The requirement the helper puts on its client: the exact app bundle
    /// that carries it, signed by the helper's own team. Nil without a team
    /// (an unsigned or ad hoc helper accepts nobody).
    public nonisolated func clientRequirement(teamID: String?, appBundleID: String) -> String? {
        guard let teamID, isPlainTeam(teamID), isPlainIdentifier(appBundleID) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(appBundleID)\""
    }

    /// The code-signing identifier of the helper executable. codesign derives
    /// it from the file name, so the build phase and scripts/sign-cmux-bundle.sh
    /// produce the same value.
    public nonisolated let helperIdentifier = "cmux-server-helper"

    /// The requirement the app puts on the helper it connects to: the helper
    /// executable signed by the app's own team. The per-build Mach service
    /// name keeps builds apart.
    public nonisolated func helperRequirement(teamID: String?) -> String? {
        guard let teamID, isPlainTeam(teamID) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(helperIdentifier)\""
    }
}

/// The helper side: validates the fix id, records the value it replaces and
/// runs exactly the fix's argv; revert restores the recorded value.
public final nonisolated class ServerHelperService: NSObject, ServerHelperProtocol, @unchecked Sendable {
    private let runner: any ServerFixRunner
    private let priors: any ServerFixPriorStore
    /// Apply and revert run one at a time, so a revert never interleaves
    /// with an apply of the same setting and loses the user's value.
    private let queue = FixQueue()

    public init(runner: any ServerFixRunner = ProcessFixRunner(), priors: any ServerFixPriorStore = MemoryFixPriorStore()) {
        self.runner = runner
        self.priors = priors
    }

    public func apply(fixID: String, reply: @escaping @Sendable (String?) -> Void) {
        guard let fix = ServerFix(rawValue: fixID) else { return reply("unknown fix") }
        let runner = runner, priors = priors, queue = queue
        Task { reply(await queue.serially { await Self.apply(fix, runner: runner, priors: priors) }) }
    }

    public func revert(fixID: String, reply: @escaping @Sendable (String?) -> Void) {
        guard let fix = ServerFix(rawValue: fixID) else { return reply("unknown fix") }
        let runner = runner, priors = priors, queue = queue
        Task { reply(await queue.serially { await Self.revert(fix, runner: runner, priors: priors) }) }
    }

    public func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(ServerHelperConstants().protocolVersion)
    }

    static func apply(_ fix: ServerFix, runner: any ServerFixRunner, priors: any ServerFixPriorStore) async -> String? {
        do {
            if priors.prior(fix) == nil {
                let current = try await runner.run(ServerFix.pmset, ["-g", "custom"])
                guard current.status == 0, let value = fix.currentValue(inCustomOutput: current.output) else {
                    return "could not read the current \(fix.setting) setting"
                }
                if value == fix.appliedValue { return nil }
                do {
                    try priors.record(fix, prior: value)
                } catch {
                    return "could not record the current \(fix.setting) setting"
                }
            }
            let result = try await runner.run(ServerFix.pmset, fix.applyArguments)
            return result.status == 0 ? nil : "pmset exited \(result.status)"
        } catch is ServerHelperTimedOut {
            return "pmset timed out"
        } catch {
            return "pmset did not start"
        }
    }

    static func revert(_ fix: ServerFix, runner: any ServerFixRunner, priors: any ServerFixPriorStore) async -> String? {
        guard let prior = priors.prior(fix) else { return "nothing to revert" }
        guard ServerFix.allowedRange.contains(prior) else { return "the recorded \(fix.setting) value is out of range" }
        do {
            let result = try await runner.run(ServerFix.pmset, fix.arguments(setting: prior))
            guard result.status == 0 else { return "pmset exited \(result.status)" }
            do {
                try priors.clear(fix)
            } catch {
                return "could not clear the recorded \(fix.setting) setting"
            }
            return nil
        } catch is ServerHelperTimedOut {
            return "pmset timed out"
        } catch {
            return "pmset did not start"
        }
    }
}
