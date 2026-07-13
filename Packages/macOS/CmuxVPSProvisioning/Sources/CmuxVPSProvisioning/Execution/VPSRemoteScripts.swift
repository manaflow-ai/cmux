internal import Foundation

/// Builds the POSIX-sh command scripts the executor runs on the host, one
/// pure function per plan step, so every script is pinned by unit tests.
public struct VPSRemoteScripts: Equatable, Sendable {
    /// Layout the scripts operate on.
    public var layout: VPSRemoteLayout

    /// Creates a script builder for `layout`.
    public init(layout: VPSRemoteLayout) {
        self.layout = layout
    }

    /// `systemctl` invocation prefix for `scope`; user scope pins
    /// `XDG_RUNTIME_DIR` so it works over a non-login SSH exec channel.
    public func systemctlPrefix(scope: VPSUnitScope) -> String {
        switch scope {
        case .system:
            return "systemctl"
        case .user:
            return "env XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user"
        }
    }

    /// Creates the versioned binary directory.
    public func makeBinaryDirectoryScript() -> String {
        "mkdir -p \(layout.binaryDirectory.shellSingleQuoted)"
    }

    /// Verifies the uploaded temp binary against `expectedSHA256`, then
    /// installs it atomically. Exits 65 on digest mismatch, printing the
    /// computed digest for the error surface.
    public func finalizeBinaryScript(tempPath: String, expectedSHA256: String) -> String {
        """
        if command -v sha256sum >/dev/null 2>&1; then
          cmux_actual="$(sha256sum \(tempPath.shellSingleQuoted) | cut -d " " -f 1)"
        else
          cmux_actual="$(shasum -a 256 \(tempPath.shellSingleQuoted) | cut -d " " -f 1)"
        fi
        if [ "$cmux_actual" != \(expectedSHA256.lowercased().shellSingleQuoted) ]; then
          printf '%s\\n' "$cmux_actual"
          rm -f \(tempPath.shellSingleQuoted)
          exit 65
        fi
        chmod 755 \(tempPath.shellSingleQuoted) && mv \(tempPath.shellSingleQuoted) \(layout.binaryPath.shellSingleQuoted)
        """
    }

    /// Retargets the stable `current` symlink at `target`.
    public func updateSymlinkScript(target: String) -> String {
        """
        mkdir -p \(layout.vpsDirectory.shellSingleQuoted)
        ln -sfn \(target.shellSingleQuoted) \(layout.currentSymlinkPath.shellSingleQuoted)
        """
    }

    /// Writes the unit file content via a quoted heredoc.
    public func writeUnitFileScript(path: String, content: String) -> String {
        """
        mkdir -p "$(dirname \(path.shellSingleQuoted))"
        cat > \(path.shellSingleQuoted) <<'CMUX_UNIT_EOF'
        \(content)CMUX_UNIT_EOF
        """
    }

    /// `systemctl daemon-reload` for `scope`.
    public func daemonReloadScript(scope: VPSUnitScope) -> String {
        "\(systemctlPrefix(scope: scope)) daemon-reload"
    }

    /// Best-effort `loginctl enable-linger` for the SSH user.
    public func enableLingerScript() -> String {
        "loginctl enable-linger \"$(id -un)\" 2>/dev/null || true"
    }

    /// `systemctl enable` for the unit.
    public func enableUnitScript(scope: VPSUnitScope) -> String {
        "\(systemctlPrefix(scope: scope)) enable \(VPSRemoteLayout.unitName.shellSingleQuoted)"
    }

    /// `systemctl restart` for the unit.
    public func restartUnitScript(scope: VPSUnitScope) -> String {
        "\(systemctlPrefix(scope: scope)) restart \(VPSRemoteLayout.unitName.shellSingleQuoted)"
    }

    /// `systemctl stop` for the unit (used by remove).
    public func stopUnitScript(scope: VPSUnitScope) -> String {
        "\(systemctlPrefix(scope: scope)) stop \(VPSRemoteLayout.unitName.shellSingleQuoted)"
    }

    /// Disables and removes the unit file, then reloads systemd (remove).
    public func removeUnitScript(scope: VPSUnitScope) -> String {
        """
        \(systemctlPrefix(scope: scope)) disable \(VPSRemoteLayout.unitName.shellSingleQuoted) 2>/dev/null || true
        rm -f \(layout.unitFilePath(scope: scope).shellSingleQuoted)
        \(systemctlPrefix(scope: scope)) daemon-reload
        """
    }

    /// Removes the VPS state directory (`~/.cmux/vps`); shared daemon state
    /// under `~/.cmux/daemon` and installed binaries are left for plain SSH
    /// workspaces.
    public func removeVPSDirectoryScript() -> String {
        "rm -rf \(layout.vpsDirectory.shellSingleQuoted)"
    }

    /// Non-spawning daemon/slot status query via `binaryPath`.
    public func daemonStatusScript(binaryPath: String) -> String {
        "\(binaryPath.shellSingleQuoted) daemon-status --slot \(VPSRemoteLayout.sharedSlot.shellSingleQuoted) --json"
    }

    /// End-to-end hello through the exact stdio + persistent-socket path
    /// workspaces use (spawns the slot daemon when nothing supervises it).
    public func stdioHelloScript(binaryPath: String) -> String {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        return "printf '%s\\n' \(request.shellSingleQuoted) | \(binaryPath.shellSingleQuoted) serve --stdio --persistent --slot \(VPSRemoteLayout.sharedSlot.shellSingleQuoted)"
    }
}
