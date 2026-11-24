public import Foundation
import CmuxNextWakeups

/// What the install check's canary chat found (the app runs it: the agent pane's
/// `AcpmuxInstallCanary`, which this package does not link).
nonisolated public enum InstallCanaryResult: Equatable, Sendable {
    case passed
    /// The hello was refused; the refusal as a chat would see it, and whether the daemon marked it
    /// retryable (cmux-install-check takes a retryable refusal as inconclusive).
    case refused(String, retryable: Bool)
    /// No answer either way; nothing is recorded and the next launch checks again.
    case inconclusive(String)
}

/// cmux NEXT NIGHTLY's install check (RFD 0028, item 6; Leo 2026-11-22: "we need to be able to have
/// the app/daemon auto heal and stuff."). Once per build, at launch, the app opens one canary chat
/// connection. The bundled CLI's Rust (`cmux __install-check`, cmux-tui `cmux-install-check`)
/// decides from the result and the record of earlier builds' results: keep; roll app and daemon
/// back together to the newest kept build that passed this same check and reads the stores; or,
/// with none, stay and report. A refused build is pinned. The person reads one notice, one line,
/// saying what happened, why, and how to undo it. A rollback's notice is held in the record and
/// shown by the next launch (the relaunch would lose a notice sent before the swap); Rust decides
/// which notice that launch shows. Swift here only gathers the inputs and acts.
@MainActor
public struct NightlyInstallCheck {
    public let updater: UpdaterService

    public init(_ updater: UpdaterService) {
        self.updater = updater
    }

    /// Only NIGHTLY builds run the check: every other build keeps its updater as it was.
    public var isEnabled: Bool { updater.identity.track == .nightlyNext }

    /// The record of builds and their results, beside the kept versions.
    var recordFile: URL {
        updater.keptVersions.root.deletingLastPathComponent().appending(path: "install-check.json", directoryHint: .notDirectory)
    }

    var cli: URL { Bundle.main.bundleURL.appending(path: "Contents/Resources/bin/cmux", directoryHint: .notDirectory) }

    /// Runs the check when this build is due one. `canary` opens the chat connection (nil: no daemon
    /// of the app's own to ask); `notify` shows the person one line (title, body).
    public func run(canary: @MainActor () async -> InstallCanaryResult?, stateDirectories: [URL?],
                    notify: @escaping @MainActor (_ title: String, _ body: String) -> Void) async {
        guard isEnabled else { return }
        let build = updater.identity.build
        await showHeld(build: build, notify: notify)
        guard await due(build: build) else { return }
        guard let result = await canary() else { return }
        let kept = await keptBuilds(refused: result, running: build, stateDirectories: stateDirectories)
        guard let decision = await decide(InstallCheckRequest(build: build, result: result, kept: kept)) else { return }
        updater.log.append("install check: \(build) \(decision.summary)")
        switch decision.action.kind {
        case .keep:
            return
        case .report:
            pin()
            let notice = NightlyInstallCheckNotice(decision.notice)
            notify(notice.title, notice.body)
        case .rollBack:
            guard let target = decision.action.to else { return }
            // `decide` held the notice in the record: the target build's launch shows it, since the
            // relaunch ends this process. Automatic, so no pick: the next newer NIGHTLY installs as set.
            if let failure = await UpdateDropBack(updater).failure(to: target, stateDirectories: stateDirectories, picksBuild: false) {
                pin()
                _ = await runCLI(["failed", "--record", recordFile.path, "--failure", failure], input: nil)
                await showHeld(build: build, notify: notify)
            }
        }
    }

    /// Shows the held rollback notice once, as `cmux __install-check show` decides for `build`.
    func showHeld(build: String, notify: @MainActor (_ title: String, _ body: String) -> Void) async {
        guard let output = await runCLI(["show", "--record", recordFile.path, "--build", build], input: nil),
              let shown = try? JSONDecoder().decode(InstallCheckShow.self, from: output) else { return }
        updater.log.append("install check: showing \(shown.kind.rawValue) for \(shown.notice.build)")
        let notice = NightlyInstallCheckNotice(shown)
        notify(notice.title, notice.body)
    }

    /// The updater's existing skip pin (a rollback sets the same): this build and older are not offered again.
    func pin() {
        let build = updater.identity.build
        updater.defaults.set(build, forKey: UpdaterService.skipsBuildsThroughKey)
        updater.controller?.skipsBuildsThrough = build
    }

    /// Whether the record holds no result for `build` yet.
    func due(build: String) async -> Bool {
        let output = await runCLI(["due", "--record", recordFile.path, "--build", build, "--nightly"], input: nil)
        return output.flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) }?["due"] == true
    }

    /// The kept builds and whether each reads the stores now (the existing rollback check), read only
    /// after a refusal: each check verifies that build's signature.
    func keptBuilds(refused result: InstallCanaryResult, running: String, stateDirectories: [URL?]) async -> [InstallCheckKept] {
        guard case .refused = result else { return [] }
        let store = updater.keptVersions
        let listed = (try? await updater.work.run(.userVisible, mayBlock: .files) { store.list(teams: false) }) ?? []
        var kept: [InstallCheckKept] = []
        for version in listed where version.build != running {
            let inputs = await updater.rollbackInputs(to: version.build, stateDirectories: stateDirectories)
            let reads = (try? updater.rollbackDecision(to: version.build, inputs: inputs).get()) != nil
            kept.append(InstallCheckKept(build: version.build, readsStore: reads))
        }
        return kept
    }

    func decide(_ request: InstallCheckRequest) async -> InstallCheckDecision? {
        guard let input = try? JSONEncoder().encode(request),
              let output = await runCLI(["decide", "--record", recordFile.path], input: input) else { return nil }
        return try? JSONDecoder().decode(InstallCheckDecision.self, from: output)
    }

    /// `cmux __install-check arguments`; nil on a launch failure, a non-zero exit or a timeout (logged).
    func runCLI(_ arguments: [String], input: Data?) async -> Data? {
        let request = ProcessRequest(cli, ["__install-check"] + arguments, input: input, timeout: .seconds(15))
        guard let outcome = try? await AsyncProcess().run(request), outcome.succeeded else {
            updater.log.append("install check: \(arguments.first ?? "") did not answer")
            return nil
        }
        return outcome.output
    }
}

/// The request `cmux __install-check decide` reads (cmux-install-check `Request`).
nonisolated struct InstallCheckRequest: Encodable, Equatable {
    var nightly = true
    var build: String
    var canary: Canary
    var kept: [InstallCheckKept]

    struct Canary: Encodable, Equatable {
        var result: String
        var reason: String?
        var retryable: Bool?
    }

    init(build: String, result: InstallCanaryResult, kept: [InstallCheckKept]) {
        self.build = build
        self.kept = kept
        switch result {
        case .passed: canary = Canary(result: "passed")
        case .refused(let reason, let retryable): canary = Canary(result: "refused", reason: reason, retryable: retryable)
        case .inconclusive: canary = Canary(result: "inconclusive")
        }
    }
}

nonisolated struct InstallCheckKept: Codable, Equatable {
    var build: String
    var readsStore: Bool
}

/// The decision `cmux __install-check decide` prints (cmux-install-check `Decision`).
nonisolated struct InstallCheckDecision: Decodable, Equatable {
    struct Action: Decodable, Equatable {
        enum Kind: String, Decodable { case keep, rollBack, report }
        var kind: Kind
        var to: String?
        var why: String?
    }

    struct Notice: Decodable, Equatable {
        var build: String
        var target: String?
        var why: String?
        var reason: String
    }

    var action: Action
    var pin: String?
    var notice: Notice?

    var summary: String {
        switch action.kind {
        case .keep: "keep"
        case .rollBack: "refused (\(notice?.reason ?? "")): rolling back to \(action.to ?? "?")"
        case .report: "refused (\(notice?.reason ?? "")): staying (\(action.why ?? "?"))"
        }
    }
}

/// The notice a launch shows for a held rollback (cmux-install-check `Show`).
nonisolated struct InstallCheckShow: Decodable, Equatable {
    enum Kind: String, Decodable { case rolledBack, rollbackFailed }
    var kind: Kind
    var notice: InstallCheckDecision.Notice
    var failure: String?
}

/// The one notice the person reads, in their language: a title and one line saying what, why and
/// how to undo or recover.
nonisolated struct NightlyInstallCheckNotice: Equatable {
    var title: String
    var body: String

    /// A refused build that stayed (no rollback target).
    init(_ notice: InstallCheckDecision.Notice?) {
        let build = notice?.build ?? "", reason = notice?.reason ?? ""
        title = UpdaterStrings.installCheckStayedTitle
        body = notice?.why == "storeUnreadable"
            ? UpdaterStrings.installCheckStoreUnreadable(build, reason)
            : UpdaterStrings.installCheckNoPassingBuild(build, reason)
    }

    /// A held rollback's notice, as the launch that shows it found it.
    init(_ shown: InstallCheckShow) {
        let notice = shown.notice, target = notice.target ?? ""
        switch shown.kind {
        case .rolledBack:
            title = UpdaterStrings.installCheckRolledBackTitle(target)
            body = UpdaterStrings.installCheckRolledBack(notice.build, notice.reason, target)
        case .rollbackFailed:
            title = UpdaterStrings.installCheckStayedTitle
            body = UpdaterStrings.installCheckRollbackFailed(notice.build, notice.reason, target,
                                                             shown.failure ?? UpdaterStrings.installCheckRollbackUnfinished)
        }
    }
}

nonisolated extension UpdaterStrings {
    // Install check (NightlyInstallCheck)
    static func installCheckRolledBackTitle(_ target: String) -> String {
        format("updater.installCheck.rolledBack.title", "cmux rolled back to build %@", target)
    }
    static func installCheckRolledBack(_ build: String, _ reason: String, _ target: String) -> String {
        format("updater.installCheck.rolledBack.body",
               "Build %1$@ could not open chats (%2$@), so cmux went back to build %3$@; to undo, install build %1$@ again in Settings > Updates.",
               build, reason, target)
    }
    static var installCheckStayedTitle: String { text("updater.installCheck.stayed.title", "This update cannot open chats") }
    static func installCheckNoPassingBuild(_ build: String, _ reason: String) -> String {
        format("updater.installCheck.noPassingBuild",
               "Build %1$@ could not open chats (%2$@) and no earlier build that could is kept, so cmux stayed on it; reinstall the previous NIGHTLY in Settings > Updates.",
               build, reason)
    }
    static func installCheckStoreUnreadable(_ build: String, _ reason: String) -> String {
        format("updater.installCheck.storeUnreadable",
               "Build %1$@ could not open chats (%2$@) and the earlier builds kept cannot read your data, so cmux stayed on it; reinstall the previous NIGHTLY in Settings > Updates.",
               build, reason)
    }
    static func installCheckRollbackFailed(_ build: String, _ reason: String, _ target: String, _ failure: String) -> String {
        format("updater.installCheck.rollbackFailed",
               "Build %1$@ could not open chats (%2$@) and going back to build %3$@ failed (%4$@); reinstall the previous NIGHTLY in Settings > Updates.",
               build, reason, target, failure)
    }
    /// The failure a held rollback shows when the app ended before saying one.
    static var installCheckRollbackUnfinished: String { text("updater.installCheck.rollbackUnfinished", "cmux quit before it finished") }
}
