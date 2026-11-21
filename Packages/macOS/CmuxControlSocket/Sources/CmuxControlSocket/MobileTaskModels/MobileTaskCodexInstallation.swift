import Foundation

/// Identifies the Codex installation and account a new task on the selected Mac will use.
struct MobileTaskCodexInstallation: Hashable, Sendable {
    let executable: String
    let home: URL

    static func resolve(
        using run: MobileTaskModelProviderStrategy.CommandRunner,
        defaultHome: URL
    ) async -> Self? {
        // Read the login environment in sh so the user's shell only needs to support exec.
        // Resolve relative paths here, while the launch working directory is still known.
        let command = #"""
        exec /bin/sh -c '
        bin=${CMUX_CUSTOM_CODEX_PATH:-}
        if [ ! -f "$bin" ] || [ ! -x "$bin" ]; then
            bin=$(command -v codex) || bin=
        fi
        case "$bin" in /*|"") ;; *) bin="$PWD/$bin" ;; esac
        home=${CODEX_HOME:-${HOME:+$HOME/.codex}}
        case "$home" in /*|"") ;; *) home="$PWD/$home" ;; esac
        printf "\000%s\000%s" "$bin" "$home"
        '
        """#
        guard let output = await run(command, .seconds(2)) else { return nil }
        // A login banner may precede the first NUL. Paths may contain newlines.
        let fields = output.components(separatedBy: "\0")
        guard fields.count == 3 else { return nil }
        return Self(
            executable: fields[1].isEmpty ? "codex" : fields[1],
            home: fields[2].isEmpty
                ? defaultHome.appendingPathComponent(".codex", isDirectory: true)
                : URL(fileURLWithPath: fields[2], isDirectory: true)
        )
    }
}
