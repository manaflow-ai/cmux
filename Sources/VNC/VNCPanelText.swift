import Foundation

enum VNCPanelText {
    static var openMacfleetWorkspacesTitle: String {
        String(localized: "vnc.command.openMacfleetWorkspaces.title", defaultValue: "Open Macfleet VNC Workspaces")
    }

    static var openMacfleetWorkspacesSubtitle: String {
        String(localized: "vnc.command.openMacfleetWorkspaces.subtitle", defaultValue: "Mac Mini Cluster")
    }

    static var stateConnecting: String {
        String(localized: "vnc.state.connecting", defaultValue: "Connecting")
    }

    static var stateConnected: String {
        String(localized: "vnc.state.connected", defaultValue: "Connected")
    }

    static var stateDisconnected: String {
        String(localized: "vnc.state.disconnected", defaultValue: "Disconnected")
    }

    static var stateFailed: String {
        String(localized: "vnc.state.failed", defaultValue: "Failed")
    }

    static var stateIdle: String {
        String(localized: "vnc.state.idle", defaultValue: "Idle")
    }

    static var reconnect: String {
        String(localized: "vnc.reconnect", defaultValue: "Reconnect")
    }

    static var noFrame: String {
        String(localized: "vnc.noFrame", defaultValue: "Waiting for VNC frames")
    }

    static var helperMissing: String {
        String(localized: "vnc.error.helperMissing", defaultValue: "The bundled VNC helper is missing.")
    }

    static var macfleetManifestMissingTitle: String {
        String(localized: "vnc.macfleet.manifestMissing.title", defaultValue: "Macfleet Manifest Missing")
    }

    static var macfleetManifestMissingMessage: String {
        String(localized: "vnc.macfleet.manifestMissing.message", defaultValue: "Create ~/.config/macfleet/hosts.json before opening VNC workspaces.")
    }

    static var macfleetOpenFailedTitle: String {
        String(localized: "vnc.macfleet.openFailed.title", defaultValue: "Could Not Open Macfleet VNC")
    }

    static var macfleetNoSessionsMessage: String {
        String(localized: "vnc.macfleet.noSessions.message", defaultValue: "No sessions tagged tag:mac-mini-cluster were found.")
    }

    static var macfleetNoCredentialsMessage: String {
        String(localized: "vnc.macfleet.noCredentials.message", defaultValue: "No VNC credentials were found for the mac mini cluster.")
    }

    static var alertOK: String {
        String(localized: "alert.ok", defaultValue: "OK")
    }

    static func workspaceDescription(sessionName: String) -> String {
        let format = String(localized: "vnc.workspace.description", defaultValue: "VNC session for %@")
        return String(format: format, sessionName)
    }

    static func macfleetPartialCredentialsMessage(openedCount: Int, missingCount: Int) -> String {
        let format = String(
            localized: "vnc.macfleet.partialCredentials.message",
            defaultValue: "Opened %d VNC workspaces. %d sessions were skipped because credentials were missing."
        )
        return String(format: format, openedCount, missingCount)
    }

    static func macfleetManifestFailed(_ detail: String) -> String {
        let format = String(localized: "vnc.macfleet.manifestFailed.message", defaultValue: "Could not read ~/.config/macfleet/hosts.json: %@")
        return String(format: format, detail)
    }

    static var helperDisconnected: String {
        String(localized: "vnc.error.helperDisconnected", defaultValue: "The VNC helper disconnected.")
    }

    static func helperLaunchFailed(_ detail: String) -> String {
        let format = String(localized: "vnc.error.helperLaunchFailed", defaultValue: "The VNC helper could not start: %@")
        return String(format: format, detail)
    }

    static func helperProtocolFailed(_ detail: String) -> String {
        let format = String(localized: "vnc.error.helperProtocolFailed", defaultValue: "The VNC helper sent invalid data: %@")
        return String(format: format, detail)
    }

    static func helperExited(_ status: Int) -> String {
        let format = String(localized: "vnc.error.helperExited", defaultValue: "The VNC helper exited with status %d.")
        return String(format: format, status)
    }

    static func socketCreationFailed(_ error: Int32) -> String {
        let format = String(localized: "vnc.error.socketCreationFailed", defaultValue: "Could not create the local VNC helper socket. errno %d")
        return String(format: format, error)
    }

    static var socketPathTooLong: String {
        String(localized: "vnc.error.socketPathTooLong", defaultValue: "The local VNC helper socket path is too long.")
    }

    static func socketBindFailed(_ error: Int32) -> String {
        let format = String(localized: "vnc.error.socketBindFailed", defaultValue: "Could not bind the local VNC helper socket. errno %d")
        return String(format: format, error)
    }

    static func socketPermissionFailed(_ error: Int32) -> String {
        let format = String(localized: "vnc.error.socketPermissionFailed", defaultValue: "Could not secure the local VNC helper socket. errno %d")
        return String(format: format, error)
    }

    static func socketListenFailed(_ error: Int32) -> String {
        let format = String(localized: "vnc.error.socketListenFailed", defaultValue: "Could not listen on the local VNC helper socket. errno %d")
        return String(format: format, error)
    }

    static func socketAcceptFailed(_ error: Int32) -> String {
        let format = String(localized: "vnc.error.socketAcceptFailed", defaultValue: "Could not accept the VNC helper connection. errno %d")
        return String(format: format, error)
    }

    static func socketReadFailed(_ error: Int32) -> String {
        let format = String(localized: "vnc.error.socketReadFailed", defaultValue: "Could not read from the VNC helper. errno %d")
        return String(format: format, error)
    }
}
