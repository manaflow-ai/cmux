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

    static func macfleetPartialCredentialsMessage(openedCount: Int, reusedCount: Int, missingCount: Int) -> String {
        let availableCount = openedCount + reusedCount
        let openedFormat: String
        if reusedCount > 0 {
            openedFormat = availableCount == 1
                ? String(
                    localized: "vnc.macfleet.partialCredentials.availableSingular",
                    defaultValue: "Opened or reused %d VNC workspace."
                )
                : String(
                    localized: "vnc.macfleet.partialCredentials.availablePlural",
                    defaultValue: "Opened or reused %d VNC workspaces."
                )
        } else if openedCount == 1 {
            openedFormat = String(
                localized: "vnc.macfleet.partialCredentials.openedSingular",
                defaultValue: "Opened %d VNC workspace."
            )
        } else {
            openedFormat = String(
                localized: "vnc.macfleet.partialCredentials.openedPlural",
                defaultValue: "Opened %d VNC workspaces."
            )
        }
        let skippedFormat = missingCount == 1
            ? String(
                localized: "vnc.macfleet.partialCredentials.skippedSingular",
                defaultValue: "%d session was skipped because credentials were missing."
            )
            : String(
                localized: "vnc.macfleet.partialCredentials.skippedPlural",
                defaultValue: "%d sessions were skipped because credentials were missing."
            )
        return String(format: openedFormat, availableCount) + " " + String(format: skippedFormat, missingCount)
    }

    static var macfleetManifestFailedMessage: String {
        String(
            localized: "vnc.macfleet.manifestFailed.message",
            defaultValue: "Check that ~/.config/macfleet/hosts.json contains valid macfleet JSON."
        )
    }

    static var helperDisconnected: String {
        String(localized: "vnc.error.helperDisconnected", defaultValue: "The VNC helper disconnected.")
    }

    static var helperLaunchFailed: String {
        String(localized: "vnc.error.helperLaunchFailed", defaultValue: "The VNC helper could not start.")
    }

    static var helperProtocolFailed: String {
        String(localized: "vnc.error.helperProtocolFailed", defaultValue: "The VNC helper sent invalid data.")
    }

    static var connectionFailed: String {
        String(localized: "vnc.error.connectionFailed", defaultValue: "VNC could not connect to the remote session.")
    }

    static var inputQueueFull: String {
        String(
            localized: "vnc.error.inputQueueFull",
            defaultValue: "VNC input is temporarily full. Reconnect the session and try again."
        )
    }

    static func helperErrorMessage(errorCode: String?) -> String {
        switch errorCode {
        case "inputQueueFull":
            return inputQueueFull
        case "connectionFailed":
            return connectionFailed
        default:
            return stateFailed
        }
    }

    static func helperExited(_ status: Int) -> String {
        _ = status
        return String(localized: "vnc.error.helperExited", defaultValue: "The VNC helper stopped unexpectedly.")
    }

    static func socketCreationFailed(_ error: Int32) -> String {
        _ = error
        return String(
            localized: "vnc.error.socketCreationFailed",
            defaultValue: "Could not create the local VNC helper socket."
        )
    }

    static func socketReadFailed(_ error: Int32) -> String {
        _ = error
        return String(localized: "vnc.error.socketReadFailed", defaultValue: "Could not read from the VNC helper.")
    }
}
