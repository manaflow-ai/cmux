public import Foundation

public enum RemoteInstallError: Error, Hashable, Sendable {
    /// The app's cmux-tui has no 40-hex commit to install.
    case badCommit
    case commitMismatch(expected: String, found: String)
    case missingArtifact(String)
    case badChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    /// The machine has neither curl nor wget.
    case noDownloader
    case downloadFailed(String)
    /// The bundled commit has no manifest and its cmux-tui tree (this key)
    /// is not published either, so no matching build exists to install.
    case treeNotPublished(key: String)
    /// The downloaded binary does not run there (`remote-probe` failed).
    case unrunnable(String)
    case notWritable(String)
    case noChecksumTool
    case remote(status: Int32, message: String)

    /// Exit codes of ``RemoteInstallPlan/fetchScript`` and ``RemoteInstallPlan/uploadScript``.
    enum Code {
        static let noChecksumTool: Int32 = 12
        static let noDownloader: Int32 = 13
        static let downloadFailed: Int32 = 14
        static let checksum: Int32 = 15
        static let unrunnable: Int32 = 16
        static let notWritable: Int32 = 17
        /// Another install or handoff holds the machine's install lock (cx-3r9mt).
        static let busy: Int32 = 18
        /// The machine's binary is no longer the build the update was decided for (cx-3r9mt).
        static let changed: Int32 = 19
    }

    /// The status of a refusal because another install holds the machine (cx-3r9mt).
    public static let busyStatus = Code.busy

    public static func fromScript(status: Int32, stderr: String) -> RemoteInstallError {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let last = lines.last ?? ""
        switch status {
        case Code.noChecksumTool: return .noChecksumTool
        case Code.noDownloader: return .noDownloader
        case Code.downloadFailed: return .downloadFailed(lines.last { !$0.hasPrefix("cmux-install") } ?? last)
        case Code.checksum:
            let words = (lines.first { $0.hasPrefix("cmux-install-checksum") } ?? "").split(separator: " ").map(String.init)
            let expected = words.firstIndex(of: "expected").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil } ?? ""
            let actual = words.firstIndex(of: "got").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil } ?? ""
            return .checksumMismatch(expected: expected, actual: actual)
        case Code.unrunnable: return .unrunnable(last)
        case Code.notWritable: return .notWritable(last)
        default: return .remote(status: status, message: last)
        }
    }

    /// The machine could not fetch the file itself; the Mac downloads it
    /// and streams it over the same SSH connection instead.
    public var fallsBackToUpload: Bool {
        switch self {
        case .noDownloader, .downloadFailed: true
        default: false
        }
    }
}

/// How the pinned cmux-tui gets onto one machine: the artifact for its
/// platform, the manifest's SHA-256, and POSIX scripts that install it into
/// a user-owned path (never sudo, never outside the user's own files).
///
/// Download: the machine fetches the file itself with `curl --http1.1 -C -`
/// (or `wget -c`) into a staging file next to the target, resuming a
/// partial file across attempts and runs: files.cmux.com is uncached and
/// slow from some networks, and HTTP/2 transfers broke mid-stream
/// (plans/cmux-next/cloud-ios.md 5.3). When the machine has no downloader
/// or cannot reach files.cmux.com, the Mac downloads the same file the
/// same way, checks the digest, and streams it over SSH (``uploadScript``).
/// Either way the machine checks the digest again and runs the staged
/// binary's `remote-probe` before renaming it over the old one.
public struct RemoteInstallPlan: Hashable, Sendable {
    public static let base = URL(string: "https://files.cmux.com/cmux-tui") ?? URL(fileURLWithPath: "/dev/null") // a test parses it
    public let commit: String
    public let artifact: String
    public let sha256: String
    public let url: URL
    public let remoteBinary: String
    /// This install's hold on the machine's install lock (cx-3r9mt): one install or handoff per
    /// machine at a time, from any Mac; the fetch and the upload script of one install share it.
    public let lockToken: String
    /// The `build_identity` the automatic update was decided for (cx-3r9mt): the script refuses
    /// when the machine's binary changed since (another Mac installed meanwhile). Nil: no check.
    public var expectedRemoteIdentity: String?

    public init(commit: String, platform: RemotePlatform, manifest: CmuxTUIManifest, remoteBinary: String,
                base: URL = RemoteInstallPlan.base, lockToken: String = RemoteInstallPlan.newLockToken()) throws(RemoteInstallError) {
        try self.init(commit: commit, artifact: platform.artifact, manifest: manifest, remoteBinary: remoteBinary, base: base,
                      lockToken: lockToken)
    }

    /// A plan for any published `artifact` of the manifest (`cmux-tui-acpmux-<target>` for the
    /// acpmux peer update), not only the cmux-tui of a platform.
    public init(commit: String, artifact: String, manifest: CmuxTUIManifest, remoteBinary: String,
                base: URL = RemoteInstallPlan.base, lockToken: String = RemoteInstallPlan.newLockToken()) throws(RemoteInstallError) {
        guard Self.isHex(commit, count: 40) else { throw .badCommit }
        guard manifest.sourceCommit.lowercased() == commit.lowercased() else {
            throw .commitMismatch(expected: commit, found: manifest.sourceCommit)
        }
        guard let digest = manifest.binaries[artifact] else { throw .missingArtifact(artifact) }
        guard Self.isHex(digest, count: 64) else { throw .badChecksum(artifact) }
        self.commit = commit.lowercased()
        self.artifact = artifact
        sha256 = digest.lowercased()
        url = base.appendingPathComponent(commit.lowercased()).appendingPathComponent(artifact)
        self.remoteBinary = remoteBinary
        self.lockToken = lockToken
    }

    /// 32 hex characters, fresh per install.
    public static func newLockToken() -> String {
        (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
    }

    /// The machine's install lock: a directory next to the binary (one binary, one lock), owned by
    /// one install's token. A lock older than 40 minutes (longer than the slowest upload) is from an install that never finished.
    private static func lockPath(remoteBinary: String) -> String {
        "$(dirname \(RemotePath.shellWord(remoteBinary)))/.cmux-tui-install.lock"
    }

    /// Gives the lock back (only this install's own); run after the daemon handoffs.
    public static func releaseLockScript(remoteBinary: String, token: String) -> String {
        """
        lock="\(lockPath(remoteBinary: remoteBinary))"
        [ "$(cat "$lock/owner" 2>/dev/null)" = '\(token)' ] && rm -rf "$lock"
        echo cmux-install-unlocked
        """
    }

    public static func manifestURL(commit: String, base: URL = RemoteInstallPlan.base) -> URL {
        base.appendingPathComponent(commit.lowercased()).appendingPathComponent("manifest.json")
    }

    /// `cmux-tui/tree/<key>/source.json`: the commit that published a tree key.
    public static func treeSourceURL(key: String, base: URL = RemoteInstallPlan.base) -> URL {
        base.appendingPathComponent("tree").appendingPathComponent(key.lowercased()).appendingPathComponent("source.json")
    }

    /// Shared prelude: target, staging file and a digest helper.
    private var prelude: String {
        """
        set -u
        umask 022
        dest=\(RemotePath.shellWord(remoteBinary))
        dir=$(dirname "$dest")
        stage="$dir/.cmux-tui-\(commit.prefix(12)).partial"
        want='\(sha256)'
        mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] || { echo "cmux-install-notwritable cannot write $dir" >&2; exit \(RemoteInstallError.Code.notWritable); }
        lock="\(Self.lockPath(remoteBinary: remoteBinary))"
        token='\(lockToken)'
        if mkdir "$lock" 2>/dev/null; then echo "$token" > "$lock/owner"
        elif [ "$(cat "$lock/owner" 2>/dev/null)" = "$token" ]; then :
        elif [ -n "$(find "$lock" -maxdepth 0 -mmin +40 2>/dev/null)" ] && mv "$lock" "$lock.stale.$token" 2>/dev/null && rm -rf "$lock.stale.$token" && mkdir "$lock" 2>/dev/null; then echo "$token" > "$lock/owner"
        else echo "cmux-install-busy another install or handoff runs on this machine" >&2; exit \(RemoteInstallError.Code.busy); fi
        expect='\(expectedRemoteIdentity.map { $0.filter { $0.isHexDigit || $0.isLetter || $0.isNumber } } ?? "")'
        if [ -n "$expect" ] && [ -x "$dest" ]; then
          cur=$("$dest" remote-probe --json 2>/dev/null | tr ',' '\\n' | sed -n 's/.*"build_identity" *: *"\\([^"]*\\)".*/\\1/p' | head -n 1)
          if [ -n "$cur" ] && [ "$cur" != "$expect" ]; then echo "cmux-install-changed the machine now runs $cur" >&2; exit \(RemoteInstallError.Code.changed); fi
        fi
        digest() {
          if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
          elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
          else echo "cmux-install-nochecksum" >&2; exit \(RemoteInstallError.Code.noChecksumTool); fi
        }

        """
    }

    /// Checks the staged file, proves it runs, then renames it into place.
    private var finish: String {
        """
        got=$(digest "$stage")
        if [ "$got" != "$want" ]; then
          rm -f "$stage"
          echo "cmux-install-checksum expected $want got $got" >&2
          exit \(RemoteInstallError.Code.checksum)
        fi
        chmod 755 "$stage"
        touch "$lock" 2>/dev/null || true
        if ! out=$("$stage" remote-probe --json 2>&1); then
          echo "cmux-install-unrunnable $out" >&2
          exit \(RemoteInstallError.Code.unrunnable)
        fi
        mv -f "$stage" "$dest"
        echo "cmux-install-ok \(commit)"

        """
    }

    /// Fetches on the machine, resuming a partial file.
    public var fetchScript: String {
        prelude + """
        url='\(url.absoluteString)'
        if [ -f "$stage" ] && [ "$(digest "$stage")" = "$want" ]; then :; else
          if command -v curl >/dev/null 2>&1; then fetch() { curl --http1.1 -fsSL --proto '=https' --connect-timeout 20 --speed-limit 1024 --speed-time 60 -C - -o "$stage" "$url"; }
          elif command -v wget >/dev/null 2>&1; then fetch() { wget -c -q -T 60 -O "$stage" "$url"; }
          else echo "cmux-install-nodownloader" >&2; exit \(RemoteInstallError.Code.noDownloader); fi
          n=0
          until touch "$lock" 2>/dev/null; fetch; do
            n=$((n + 1))
            if [ "$n" -ge 6 ]; then echo "cmux-install-download failed after $n attempts" >&2; exit \(RemoteInstallError.Code.downloadFailed); fi
            sleep "$n"
          done
        fi

        """ + finish
    }

    /// The staged file next to the target, as a remote path.
    public var stagePath: String {
        let directory = (remoteBinary as NSString).deletingLastPathComponent
        return (directory.isEmpty ? "." : directory) + "/.cmux-tui-\(commit.prefix(12)).partial"
    }

    /// The remote command that receives the Mac's copy on stdin. A plain
    /// `mkdir`/`cat` line reads the same in sh, bash, zsh, fish and csh
    /// (paths are plain words, `RemotePath.isSafe`), so the binary never
    /// passes through a shell parser.
    public var uploadCommand: String {
        let directory = (remoteBinary as NSString).deletingLastPathComponent
        return "mkdir -p \(directory.isEmpty ? "." : directory) && cat > \(stagePath)"
    }

    /// Checks and installs the file ``uploadCommand`` staged.
    public var uploadScript: String {
        prelude + """
        [ -f "$stage" ] || { echo "cmux-install-upload missing $stage" >&2; exit \(RemoteInstallError.Code.downloadFailed); }

        """ + finish
    }

    /// `/usr/bin/curl` arguments for the Mac-side download: HTTP/1.1,
    /// resuming `file` when it exists, HTTPS only.
    public func localDownloadArguments(to file: URL) -> [String] {
        ["--http1.1", "-fsSL", "--proto", "=https", "--connect-timeout", "20", "--speed-limit", "1024", "--speed-time", "60",
         "--retry", "5", "--retry-all-errors", "-C", "-", "-o", file.path, url.absoluteString]
    }

    /// After an upgrade: stop the SSH sidecar (`remote stop`, which never
    /// stops terminals) and SIGTERM the session's daemon when `daemonPID`
    /// (from its `identify`) still runs that session's cmux-tui. A daemon
    /// hands its terminal hosts off on SIGTERM (docs/cloud-guest-upgrades.md),
    /// and the next link starts the new build, which adopts them. Terminal
    /// hosts are never signalled; `--end-terminals` is never used. The
    /// machine's acpmux is handed over by the app after this script
    /// (`SSHService.handOffAgentDaemonAfterInstall`).
    public static func restartScript(host: SSHHost, daemonPID: Int32?) -> String {
        var script = """
        B=\(RemotePath.shellWord(host.remoteBinary))
        "$B" remote stop --session \(RemotePath.quote(host.session))\(host.remoteStateDir.map { " --state-dir " + RemotePath.shellWord($0) } ?? "") >/dev/null 2>&1 || true

        """
        if let daemonPID, daemonPID > 1 {
            script += """
            args=$(ps -o args= -p \(daemonPID) 2>/dev/null || true)
            # A daemon that re-executed itself shows `/proc/self/exe` as its argv[0]: its
            # executable (Linux /proc, else lsof's text file) names cmux-tui, also once replaced
            # ("(deleted)").
            exe=$(readlink /proc/\(daemonPID)/exe 2>/dev/null || lsof -a -p \(daemonPID) -d txt -Fn 2>/dev/null | sed -n 's/^n//p' || true)
            case "$args" in
              *"--session \(host.session)"|*"--session \(host.session) "*) case "$exe $args" in *cmux-tui*) kill -TERM \(daemonPID) 2>/dev/null || true ;; esac ;;
            esac

            """
        }
        return script + "echo cmux-restart-ok\n"
    }

    static func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
