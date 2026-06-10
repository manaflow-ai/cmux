import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - cmux omx and omc launchers
extension CMUXCLI {
    private func resolveOMXExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("omx", searchPath: searchPath)
    }

    private func createOMXShimDirectory() throws -> URL {
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
          show-options|show-option|show)
            shift
            value_only=0
            option_name=""
            while (($#)); do
              arg="$1"
              shift
              case "$arg" in
                --) ;;
                -t)
                  if (($#)); then shift; fi
                  ;;
                -t*) ;;
                -*)
                  case "$arg" in
                    *v*) value_only=1 ;;
                  esac
                  ;;
                *) option_name="$arg" ;;
              esac
            done
            case "$option_name" in
              extended-keys)
                if [[ "$value_only" == "1" ]]; then
                  echo "on"
                else
                  echo "extended-keys on"
                fi
                exit 0
                ;;
            esac
            ;;
        esac
        exec "${CMUX_OMX_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "omx-bin",
            tmuxShimScript: tmuxScript
        )
    }

    private func configureOMXEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-omx",
            cmuxBinEnvVar: "CMUX_OMX_CMUX_BIN",
            termOverrideEnvVar: "CMUX_OMX_TERM"
        )
    }

    func runOMX(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath; launcherEnvironment.removeValue(forKey: "CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        guard let omxExecutablePath = resolveOMXExecutable(searchPath: launcherEnvironment["PATH"]) else {
            throw CLIError(message: "omx is not installed. Install it first:\n  npm install -g oh-my-codex\n\nThen run: cmux omx")
        }
        launcherEnvironment["PATH"] = providerExecutableSearchPath(
            searchPath: launcherEnvironment["PATH"],
            includingExecutableAt: omxExecutablePath
        )

        let shimDirectory = try createOMXShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = try tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        configureOMXEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = omxExecutablePath
        exportAgentLaunchCommandEnvironment(
            launcher: "omx",
            executablePath: executablePath,
            arguments: [executablePath, "omx"] + commandArgs,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + commandArgs).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        execv(launchPath, &argv)
        let code = errno
        throw CLIError(message: "Failed to launch omx: \(String(cString: strerror(code)))\n\nIs oh-my-codex installed? Install with:\n  npm install -g oh-my-codex")
    }

    // MARK: - cmux omc (Oh My Claude Code)

    private func resolveOMCExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("omc", searchPath: searchPath)
    }

    private func createOMCShimDirectory() throws -> URL {
        let tmuxScript = """
        #!/usr/bin/env bash
        set -euo pipefail
        case "${1:-}" in
          -V|-v) echo "tmux 3.4"; exit 0 ;;
        esac
        exec "${CMUX_OMC_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        return try createTmuxCompatShimDirectory(
            directoryName: "omc-bin",
            tmuxShimScript: tmuxScript
        )
    }

    private func configureOMCEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: TmuxCompatFocusedContext?
    ) {
        configureTmuxCompatEnvironment(
            processEnvironment: processEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext,
            tmuxPathPrefix: "cmux-omc",
            cmuxBinEnvVar: "CMUX_OMC_CMUX_BIN",
            termOverrideEnvVar: "CMUX_OMC_TERM"
        )
        // omc wraps Claude Code, so it needs the same NODE_OPTIONS restore module
        guard let restoreModuleURL = try? createClaudeNodeOptionsRestoreModule() else {
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT")
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
            return
        }
        if let existing = processEnvironment["NODE_OPTIONS"] {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "1", 1)
            setenv("CMUX_ORIGINAL_NODE_OPTIONS", normalizedNodeOptionsForRestore(existing), 1)
        } else {
            setenv("CMUX_ORIGINAL_NODE_OPTIONS_PRESENT", "0", 1)
            unsetenv("CMUX_ORIGINAL_NODE_OPTIONS")
        }
        setenv(
            "NODE_OPTIONS",
            mergedNodeOptions(
                existing: processEnvironment["NODE_OPTIONS"],
                restoreModulePath: restoreModuleURL.path
            ),
            1
        )
    }

    func runOMC(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath; launcherEnvironment.removeValue(forKey: "CMUX_SOCKET")
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }

        guard let omcExecutablePath = resolveOMCExecutable(searchPath: launcherEnvironment["PATH"]) else {
            throw CLIError(message: "omc is not installed. Install it first:\n  npm install -g oh-my-claude-sisyphus\n\nThen run: cmux omc")
        }
        launcherEnvironment["PATH"] = providerExecutableSearchPath(
            searchPath: launcherEnvironment["PATH"],
            includingExecutableAt: omcExecutablePath
        )

        let shimDirectory = try createOMCShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = try tmuxCompatFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        configureOMCEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = omcExecutablePath
        exportAgentLaunchCommandEnvironment(
            launcher: "omc",
            executablePath: executablePath,
            arguments: [executablePath, "omc"] + commandArgs,
            workingDirectory: launcherEnvironment["PWD"]
        )
        var argv = ([launchPath] + commandArgs).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        execv(launchPath, &argv)
        let code = errno
        throw CLIError(message: "Failed to launch omc: \(String(cString: strerror(code)))\n\nIs oh-my-claude-sisyphus installed? Install with:\n  npm install -g oh-my-claude-sisyphus")
    }

}
