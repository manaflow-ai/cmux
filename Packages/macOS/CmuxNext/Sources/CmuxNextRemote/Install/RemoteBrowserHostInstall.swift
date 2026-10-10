public import Foundation

/// Installs a browser host bundle on a macOS SSH machine (cx-2cob slice 2,
/// upload from this Mac): the app sends a gzip tar of its own host app
/// (`cmux-remote-browser-host.app`, its CEF framework included) on ssh's
/// stdin; the machine unpacks it to
/// `~/Library/Application Support/cmux-tui/browser-host/<version>/host.app`
/// and points `current` at it, where the daemon's `browser-runtime-start`
/// looks. Never sudo; only that user-owned directory changes. A failed
/// upload leaves the previous version in place.
public struct RemoteBrowserHostInstall: Sendable {
    /// The installed version's name: the host binary's sha256.
    public let version: String

    public init?(version: String) {
        guard version.count == 64, version.allSatisfy(\.isHexDigit) else { return nil }
        self.version = version.lowercased()
    }

    /// The machine-side script; the tar comes on stdin.
    public var script: String {
        """
        set -eu
        umask 022
        root="$HOME/Library/Application Support/cmux-tui/browser-host"
        dest="$root/\(version)"
        stage="$root/.\(version).partial"
        mkdir -p "$root"
        rm -rf "$stage"
        mkdir -p "$stage"
        tar -xzf - -C "$stage"
        [ -x "$stage/cmux-remote-browser-host.app/Contents/MacOS/cmux-remote-browser-host" ] || { echo "cmux-browser-install: the bundle has no host" >&2; exit 3; }
        mv "$stage/cmux-remote-browser-host.app" "$stage/host.app"
        rm -rf "$dest"
        mv "$stage" "$dest"
        ln -sfhn "$dest" "$root/current"
        for old in "$root"/*; do
          case "$old" in "$dest"|"$root/current"|"$root/logs") ;; *) [ -d "$old" ] && rm -rf "$old" ;; esac
        done
        echo "cmux-browser-installed \(version)"
        """
    }

    /// Runs the script on `host` with `bundle` (a gzip tar) on stdin.
    public func run(on host: SSHHost, bundle: URL, environment: [String: String],
                    commandLine: SSHCommandLine = SSHCommandLine()) async throws -> SSHProcessResult {
        let command = "sh -c " + RemotePath.shellWord(script)
        return try await SSHProcessRunner.run(commandLine.command(host, command), input: .file(bundle), environment: environment,
                                              deadline: .seconds(30 * 60), label: "install the browser on \(host.destination)")
    }
}
