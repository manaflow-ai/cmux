import Foundation

extension DockSplitStore {
    static func resolvedWorkingDirectory(_ cwd: String?, baseDirectory: String) -> String {
        guard let cwd, !cwd.isEmpty else { return baseDirectory }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseDirectory as NSString).appendingPathComponent(cwd)
    }

    static func shellStartupScript(command: String, workingDirectory: String) -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-dock-control-\(UUID().uuidString.lowercased()).sh"
        )
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let encodedWorkingDirectory = Data(workingDirectory.utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_dock_decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
        cmux_dock_login_shell() {
          cmux_dock_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
          cmux_dock_ds_shell="$(dscl . -read "/Users/$cmux_dock_user" UserShell 2>/dev/null | awk '{print $2; exit}')"
          if [ -n "$cmux_dock_ds_shell" ] && [ -x "$cmux_dock_ds_shell" ]; then printf '%s\\n' "$cmux_dock_ds_shell"
          elif [ -n "${SHELL:-}" ] && [ -x "${SHELL:-}" ]; then printf '%s\\n' "$SHELL"
          else printf '%s\\n' /bin/sh; fi
        }
        cmux_dock_command="$(cmux_dock_decode '\(encodedCommand)')"
        cmux_dock_working_directory="$(cmux_dock_decode '\(encodedWorkingDirectory)')"
        cmux_dock_shell="$(cmux_dock_login_shell)"
        cmux_dock_bundle_bin=""
        if [ -n "${CMUX_BUNDLED_CLI_PATH:-}" ]; then cmux_dock_bundle_bin="$(dirname "$CMUX_BUNDLED_CLI_PATH")"; fi
        export SHELL="$cmux_dock_shell"
        rm -f -- "$0" 2>/dev/null || true
        case "$(basename "$cmux_dock_shell")" in
          fish)
            CMUX_DOCK_BUNDLE_BIN="$cmux_dock_bundle_bin" CMUX_DOCK_START_COMMAND="$cmux_dock_command" CMUX_DOCK_START_DIRECTORY="$cmux_dock_working_directory" "$cmux_dock_shell" -l -c 'if test -n "$CMUX_DOCK_BUNDLE_BIN"; and not contains -- "$CMUX_DOCK_BUNDLE_BIN" $PATH; set -gx PATH "$CMUX_DOCK_BUNDLE_BIN" $PATH; end; if test -n "$CMUX_DOCK_START_DIRECTORY"; cd "$CMUX_DOCK_START_DIRECTORY"; end; eval "$CMUX_DOCK_START_COMMAND"'
            ;;
          *) CMUX_DOCK_BUNDLE_BIN="$cmux_dock_bundle_bin" CMUX_DOCK_START_COMMAND="$cmux_dock_command" CMUX_DOCK_START_DIRECTORY="$cmux_dock_working_directory" "$cmux_dock_shell" -lc 'if [ -n "${CMUX_DOCK_BUNDLE_BIN:-}" ]; then case ":${PATH:-}:" in *":$CMUX_DOCK_BUNDLE_BIN:"*) ;; *) PATH="$CMUX_DOCK_BUNDLE_BIN${PATH:+:$PATH}"; export PATH ;; esac; fi; cd "$CMUX_DOCK_START_DIRECTORY" 2>/dev/null || true; eval "$CMUX_DOCK_START_COMMAND"'
            ;;
        esac
        printf '\\n'
        exec "$cmux_dock_shell" -l
        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }
}
