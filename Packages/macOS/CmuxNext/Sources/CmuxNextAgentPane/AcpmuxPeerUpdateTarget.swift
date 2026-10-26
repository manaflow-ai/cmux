import CmuxNextWakeups
import Foundation
import os

/// An acpmux ssh peer of this app's daemon (`acpmux host add NAME ssh://host`) as a
/// ``DaemonUpdateTarget``: `acpmux --json host update NAME --binary-dir DIR --keep-newer [--if-idle]` on the
/// bundled CLI. By default the policy asks without `--if-idle`, which restarts the peer's daemon
/// mid-turn; the new daemon resumes what it interrupted. With the policy's optional busy cap it
/// asks with `--if-idle` first (the CLI then refuses a peer where any session runs a turn: `busy`)
/// until the peer stayed busy for the cap. The CLI keeps the old binary and rolls back by itself when the new daemon does not
/// come up with the expected build.
/// When it asks for the peer's platform binary (`needsBinary`), the published
/// `cmux-tui-acpmux-<target>` of the bundled build is downloaded, staged and the update runs again.
nonisolated struct AcpmuxPeerUpdateTarget: DaemonUpdateTarget {
    let name: String
    let url: String
    let source: AcpmuxPeerUpdateSource

    var id: String { "acpmux-peer:\(name)" }
    var displayName: String { name }
    var sshHost: String? { AcpmuxPeerUpdateStatus.host(ofURL: url) }

    /// The peer's build while it is connected, from the local daemon's status.
    func currentBuild() async -> String? {
        await source.status()?.peers.first { $0.name == name && $0.connected }?.remoteBuild
    }

    func update(to build: DaemonBuildCommit, whileBusy: Bool) async -> DaemonUpdateOutcome {
        let binaries = source.binaryDirectory(hash: build.hash)
        var reply = await source.hostUpdate(name, binaries: binaries, whileBusy: whileBusy)
        if case .needsBinary(let triple) = reply.outcome {
            do {
                try await source.stage("cmux-tui-acpmux-\(triple)", as: binaries.appendingPathComponent("acpmux-\(triple)"), for: build)
            } catch {
                AcpmuxPeerUpdateSource.logger.error("\(name, privacy: .public): no binary for \(triple, privacy: .public): \(String(describing: error), privacy: .public)")
                return .needsBinary(target: triple)
            }
            reply = await source.hostUpdate(name, binaries: binaries, whileBusy: whileBusy)
            if case .needsBinary = reply.outcome { return .failed(reason: "it still asks for acpmux-\(triple) after it was staged") }
        }
        switch reply.outcome {
        case .updated: return .updated(build: reply.build)
        case .current: return .current
        case .busy: return .busy
        case .needsBinary(let triple): return .needsBinary(target: triple)
        case .rolledBack: return .rolledBack(reason: reply.error ?? "the new acpmux did not start")
        case .cloudMachine: return .handledElsewhere
        // Not reachable now: the policy asks again with backoff, and drops it while the local
        // daemon reports it disconnected (``currentBuild()``) until it connects again.
        case .unreachable: return .busy
        case .failed: return .failed(reason: reply.error ?? "acpmux host update failed")
        }
    }
}

/// The acpmux side of the update: the local daemon's status, the bundled CLI, the binaries staged
/// for `--binary-dir`, and which peers are targets now.
nonisolated struct AcpmuxPeerUpdateSource: Sendable {
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon-update.acpmux")

    /// The local daemon's `_acpmux/status`; nil when it does not answer or is not this app's.
    var status: @Sendable () async -> AcpmuxPeerUpdateStatus?
    /// The bundled acpmux's build (`--version`).
    var bundledBuild: @Sendable () async -> String?
    var command: AcpmuxPeerUpdateCommand
    /// `cmux-tui-acpmux-<target>` of the bundled build, checked and cached on this Mac: the file and
    /// the 40-hex commit it was published for.
    var download: @Sendable (_ artifact: String) async throws -> (file: URL, commit: String)
    /// `<directory>/binaries/<hash>` is the `--binary-dir`.
    var directory: URL
    var clock: any Clock<Duration>
    /// Spacing of the status reads while ssh peers are still connecting after the daemon started.
    var settleBackoff = Backoff(initial: .seconds(15), maximum: .seconds(60), multiplier: 2, jitter: 0)
    /// How long it waits for ssh peers to connect.
    var settleLimit: Duration = .seconds(180)

    /// The connected ssh peers, once they connected (or after ``settleLimit``), while the local
    /// daemon may push its build; none otherwise.
    func targets() async -> [any DaemonUpdateTarget] {
        guard let status = await settledStatus() else {
            Self.logger.info("acpmux peers skipped: no local status")
            return []
        }
        if let blocked = status.blocked(bundledBuild: await bundledBuild()) {
            Self.logger.info("acpmux peers skipped: \(blocked, privacy: .public)")
            return []
        }
        return status.updatablePeers.map { AcpmuxPeerUpdateTarget(name: $0.name, url: $0.url, source: self) }
    }

    /// The status once every ssh peer connected and named its build, or after ``settleLimit``: a
    /// launch right after an update restarts the daemon, and its peers connect over ssh after it.
    private func settledStatus() async -> AcpmuxPeerUpdateStatus? {
        var backoff = settleBackoff
        var waited = Duration.zero
        while let status = await status() {
            let connecting = status.peers.contains { $0.isSSH && (!$0.connected || $0.remoteBuild == nil) }
            let delay = backoff.next()
            guard connecting, waited + delay <= settleLimit else { return status }
            // wakeup-allow: a few spaced status reads once per launch while ssh peers connect, at most 3 minutes
            do { try await clock.sleep(for: delay) } catch { return nil }
            waited += delay
        }
        return nil
    }

    /// One `host update` run and its reply; a run that prints no reply is a failure. `whileBusy`
    /// drops `--if-idle` (``AcpmuxPeerUpdateCommand/updateArguments(peer:binaryDirectory:whileBusy:)``).
    func hostUpdate(_ name: String, binaries: URL, whileBusy: Bool) async -> AcpmuxPeerUpdateReply {
        let result = await command.run(AcpmuxPeerUpdateCommand.updateArguments(peer: name, binaryDirectory: binaries, whileBusy: whileBusy))
        if let reply = AcpmuxPeerUpdateReply.parse(result.output, peer: name) { return reply }
        let last = result.errors.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        return AcpmuxPeerUpdateReply(outcome: .failed, error: last ?? "acpmux exited \(result.status.map(String.init) ?? "without a status")")
    }

    /// `<directory>/binaries/<hash>`; the binaries of other builds are removed.
    func binaryDirectory(hash: String) -> URL {
        let root = directory.appendingPathComponent("binaries", isDirectory: true)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where old != hash {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(old))
        }
        return root.appendingPathComponent(hash, isDirectory: true)
    }

    struct StageError: Error, CustomStringConvertible {
        var description: String
    }

    /// Downloads `artifact` of the bundled build and places it as `file` (mode 755), unless the
    /// published build is another commit than `build` (a tree build of an earlier commit): its
    /// daemon would report another build and the CLI would roll it back.
    func stage(_ artifact: String, as file: URL, for build: DaemonBuildCommit) async throws {
        let (downloaded, commit) = try await download(artifact)
        guard build.sameCommit(commit) else {
            throw StageError(description: "published build \(commit.prefix(12)) is not \(build.hash)")
        }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".\(file.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: downloaded, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: staging, to: file)
    }
}
