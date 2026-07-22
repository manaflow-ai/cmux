import Foundation

/// LaunchServices arguments and environment for the standalone helper daemon.
struct ComputerUseHelperLaunchConfiguration: Equatable, Sendable {
    let arguments: [String]
    let environment: [String: String]

    init(paths: ComputerUseRuntimePaths) {
        arguments = [
            "serve",
            "--socket",
            paths.daemonSocketURL.path,
            "--no-permissions-gate",
            "--cursor-shape",
            "cmux",
        ]
        environment = [
            "CUA_DRIVER_RS_EXTERNAL_PERMISSION_FLOW": "1",
            "CUA_DRIVER_RS_PERMISSIONS_GATE": "0",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            "CUA_DRIVER_CURSOR_GRADIENT": "#12c7f5,#2d8cff,#6c5cff",
            "CUA_DRIVER_CURSOR_BLOOM": "#2d8cff",
            "CUA_DRIVER_CURSOR_LABEL": "cmux",
            "CUA_DRIVER_STATE_DIR": paths.stateDirectoryURL.path,
            ComputerUseRuntimePaths.authenticationTokenEnvironmentKey: paths.authenticationToken,
        ]
    }
}
