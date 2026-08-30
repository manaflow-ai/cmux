import Foundation

/// LaunchServices arguments and environment for the cmux-cua helper daemon.
struct ComputerUseHelperLaunchConfiguration: Equatable, Sendable {
    let arguments: [String]
    let environment: [String: String]

    init?(
        paths: ComputerUseRuntimePaths,
        profile: ComputerUseDaemonProfile = .native,
        rootProcessIdentity: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier
        )
    ) {
        guard let rootProcessIdentity else { return nil }
        var arguments = [
            "serve",
            "--socket",
            profile == .native
                ? paths.daemonSocketURL.path
                : paths.codexDaemonSocketURL.path,
        ]
        if profile == .codexCompatibility {
            arguments.append("--codex-computer-use-compat")
        }
        arguments.append(contentsOf: [
            "--no-permissions-gate",
            "--cursor-shape",
            "cmux",
            // The proxy's control connection owns cursor teardown and sends
            // session_end on EOF/crash. A wall-clock idle timer measures gaps
            // between model calls, not task completion, and hides the cursor
            // while a still-active agent is inspecting the returned state.
            "--idle-hide-ms",
            "0",
            // Glide-speed multiplier over the driver's stock 900 pts/s peak.
            // Stock pacing reads as sluggish between agent actions; press and
            // dwell visuals keep their durations so clicks stay legible.
            "--cursor-speed",
            "1.75",
        ])
        self.arguments = arguments
        environment = [
            "CMUX_CUA_EXTERNAL_PERMISSION_FLOW": "1",
            "CMUX_CUA_PERMISSIONS_GATE": "0",
            // LaunchServices already establishes the helper as a separate GUI
            // responsibility. The cmux-cua helper is already the canonical
            // executable inside its branded bundle, so it must not re-exec or
            // launch a second `serve` process.
            "CMUX_CUA_RESPONSIBILITY_DISCLAIMED": "1",
            "CMUX_CUA_TELEMETRY_ENABLED": "false",
            "CMUX_CUA_UPDATE_CHECK": "false",
            "CMUX_CUA_CURSOR_GRADIENT": "#12c7f5,#2d8cff,#6c5cff",
            "CMUX_CUA_CURSOR_BLOOM": "#2d8cff",
            "CMUX_CUA_CURSOR_LABEL": "cmux",
            "CMUX_CUA_STATE_DIR": paths.stateDirectoryURL.path,
            ComputerUseRuntimePaths.authenticationTokenEnvironmentKey: paths.authenticationToken,
            ComputerUseRuntimePaths.hostAuthenticationTokenEnvironmentKey:
                paths.hostAuthenticationToken,
            "CMUX_CUA_SOCKET_AUTHORIZED_ROOT_PID":
                String(rootProcessIdentity.pid),
            "CMUX_CUA_SOCKET_AUTHORIZED_ROOT_START_SECONDS":
                String(rootProcessIdentity.startSeconds),
            "CMUX_CUA_SOCKET_AUTHORIZED_ROOT_START_MICROSECONDS":
                String(rootProcessIdentity.startMicroseconds),
        ]
    }
}
