import CmuxNextCloud
public import Foundation
import os

/// Installs the app's own cmux-tui build on an SSH machine (after the user
/// confirmed): the manifest from files.cmux.com, the machine's own resumable
/// HTTP/1.1 fetch, the Mac-side download and upload when the machine cannot
/// fetch, and a restart that hands terminals to the new daemon. Never sudo;
/// only the user-owned `SSHHost.remoteBinary` changes.
public struct RemoteInstaller: Sendable {
    public enum Phase: Sendable, Equatable {
        case manifest
        case remoteDownload
        case localDownload
        case upload
        case restart
    }

    private let commandLine: SSHCommandLine
    private let paths: SSHPaths
    private let session: URLSession
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "ssh.install")

    public init(commandLine: SSHCommandLine = SSHCommandLine(), paths: SSHPaths, session: URLSession = .shared) {
        self.commandLine = commandLine
        self.paths = paths
        self.session = session
    }

    /// The pinned build for `platform`, checked against its manifest.
    ///
    /// Only commits the cmux-tui artifacts job published have a manifest. A
    /// dev build compiles its cmux-tui tree itself, and the same tree was
    /// published under its tree key (`treeKey`, `key=` in cmux-tui.version)
    /// by an earlier commit T: on a 404 the plan is T's build, whose digest
    /// must also match the tree's own `source.json` (cx-z0uk). Release and
    /// nightly builds always have their own manifest.
    public func plan(commit: String, treeKey: String? = nil, platform: RemotePlatform, remoteBinary: String) async throws -> RemoteInstallPlan {
        let (status, data) = try await get(RemoteInstallPlan.manifestURL(commit: commit))
        if status == 200 {
            return try RemoteInstallPlan(commit: commit, platform: platform, manifest: CmuxTUIManifest.decode(data), remoteBinary: remoteBinary)
        }
        let noManifest = RemoteInstallError.downloadFailed("manifest: HTTP \(status)")
        guard status == 404, let treeKey, RemoteInstallPlan.isHex(treeKey, count: 40) else { throw noManifest }
        let (sourceStatus, sourceData) = try await get(RemoteInstallPlan.treeSourceURL(key: treeKey))
        guard sourceStatus == 200 else { throw sourceStatus == 404 ? RemoteInstallError.treeNotPublished(key: treeKey) : noManifest }
        guard let tree = try? CmuxTUITreeSource.decode(sourceData) else {
            throw RemoteInstallError.downloadFailed("tree \(treeKey.prefix(12)): unreadable source.json")
        }
        guard tree.key.lowercased() == treeKey.lowercased(), RemoteInstallPlan.isHex(tree.commit, count: 40) else { throw RemoteInstallError.badCommit }
        let (treeStatus, treeData) = try await get(RemoteInstallPlan.manifestURL(commit: tree.commit))
        guard treeStatus == 200 else { throw RemoteInstallError.downloadFailed("manifest of tree \(treeKey.prefix(12)): HTTP \(treeStatus)") }
        let plan = try RemoteInstallPlan(commit: tree.commit, platform: platform, manifest: CmuxTUIManifest.decode(treeData),
                                         remoteBinary: remoteBinary)
        // Two records of one published binary: they must agree, else nothing
        // installs. A tree that does not list the artifact does not vouch for it.
        let treeDigest = tree.binaries[plan.artifact]?.lowercased() ?? "absent"
        if treeDigest != plan.sha256 {
            throw RemoteInstallError.checksumMismatch(expected: plan.sha256, actual: treeDigest)
        }
        logger.info("no manifest for \(commit, privacy: .public); installing tree \(treeKey, privacy: .public) from \(tree.commit, privacy: .public)")
        return plan
    }

    /// GET `url` as JSON: the status and body. The query string bypasses a
    /// 404 the CDN edge cached before the build was published.
    private func get(_ url: URL) async throws -> (status: Int, data: Data) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: components?.url ?? url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Installs `plan` on `host`, then restarts its session's daemon
    /// (`daemonPID` from its `identify`, nil when none runs).
    public func install(_ plan: RemoteInstallPlan, on host: SSHHost, daemonPID: Int32?, environment: [String: String],
                        progress: @Sendable (Phase) -> Void) async throws {
        progress(.remoteDownload)
        let fetched = try await ssh(host, script: plan.fetchScript, environment: environment, label: "remote install")
        if fetched.status != 0 {
            let error = try failure(fetched)
            guard error.fallsBackToUpload else { throw error }
            logger.info("\(host.destination.description, privacy: .public) cannot fetch (\(String(describing: error), privacy: .public)); uploading")
            progress(.localDownload)
            let file = try await localCopy(plan, environment: environment)
            progress(.upload)
            let uploaded = try await SSHProcessRunner.run(commandLine.command(host, plan.uploadCommand), input: .file(file),
                                                       environment: environment, deadline: .seconds(1800),
                                                       label: "upload cmux-tui to \(host.destination)")
            if uploaded.status == 255, let failure = SSHFailure.classify(status: 255, stderr: uploaded.stderr) { throw failure }
            guard uploaded.status == 0 else { throw RemoteInstallError.notWritable(uploaded.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let installed = try await ssh(host, script: plan.uploadScript, environment: environment, label: "remote install")
            guard installed.status == 0 else { throw try failure(installed) }
        }
        progress(.restart)
        _ = try await ssh(host, script: RemoteInstallPlan.restartScript(host: host, daemonPID: daemonPID), environment: environment,
                          label: "restart cmux-tui", deadline: .seconds(60))
    }

    private func ssh(_ host: SSHHost, script: String, environment: [String: String], label: String,
                     deadline: Duration = .seconds(1800)) async throws -> SSHProcessResult {
        let result = try await SSHProcessRunner.run(commandLine.script(host), input: .data(Data(script.utf8)), environment: environment,
                                                 deadline: deadline, label: "\(label) \(host.destination)")
        if result.status == 255, let failure = SSHFailure.classify(status: 255, stderr: result.stderr) { throw failure }
        return result
    }

    private func failure(_ result: SSHProcessResult) throws -> RemoteInstallError {
        RemoteInstallError.fromScript(status: result.status, stderr: result.stderr)
    }

    /// The artifact in the download cache, fetched with resume when needed
    /// and checked against the manifest digest.
    func localCopy(_ plan: RemoteInstallPlan, environment: [String: String]) async throws -> URL {
        try paths.prepare()
        let file = paths.downloads.appendingPathComponent("\(plan.artifact)-\(plan.commit.prefix(12))")
        if (try? SHA256File.verify(file, expected: plan.sha256)) != nil { return file }
        let partial = file.appendingPathExtension("partial")
        let result = try await SSHProcessRunner.run(["/usr/bin/curl"] + plan.localDownloadArguments(to: partial), environment: environment,
                                                 deadline: .seconds(1800), label: "download \(plan.artifact)")
        guard result.status == 0 else {
            throw RemoteInstallError.downloadFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            try SHA256File.verify(partial, expected: plan.sha256)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: partial, to: file)
        return file
    }
}

/// The commit of the app's bundled cmux-tui: `cmux-tui.version` next to the
/// binary (`commit=`), else the commit in `cmux-tui --version`.
public struct BundledCmuxTUI {
    public init() {}
    public static func commit(binary: URL) async -> String? {
        let versionFile = binary.deletingLastPathComponent().appendingPathComponent("cmux-tui.version")
        if let text = try? String(contentsOf: versionFile, encoding: .utf8),
           let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("commit=") }) {
            let commit = String(line.dropFirst("commit=".count))
            if RemoteInstallPlan.isHex(commit, count: 40) { return commit.lowercased() }
        }
        guard let result = try? await SSHProcessRunner.run([binary.path, "--version"], environment: ProcessInfo.processInfo.environment,
                                                        deadline: .seconds(10), label: "cmux-tui --version") else { return nil }
        return commit(inVersion: result.stdout)
    }

    /// The cmux-tui tree key of a tree-mode bundle (`key=` in
    /// cmux-tui.version, 40 hex), nil for a pinned build or a missing file.
    public static func treeKey(binary: URL) -> String? {
        let versionFile = binary.deletingLastPathComponent().appendingPathComponent("cmux-tui.version")
        guard let text = try? String(contentsOf: versionFile, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.contains("mode=tree"), let line = lines.first(where: { $0.hasPrefix("key=") }) else { return nil }
        let key = String(line.dropFirst("key=".count))
        return RemoteInstallPlan.isHex(key, count: 40) ? key.lowercased() : nil
    }

    /// `cmux 0.1.0 (c27a76e…; ghostty …)` → the 40-hex commit.
    static func commit(inVersion text: String) -> String? {
        text.split { !$0.isHexDigit }.map(String.init).first { RemoteInstallPlan.isHex($0, count: 40) }?.lowercased()
    }
}
