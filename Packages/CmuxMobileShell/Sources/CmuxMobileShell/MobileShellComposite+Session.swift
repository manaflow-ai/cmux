public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog


// MARK: - Session lifecycle
extension MobileShellComposite {
    public func signIn() {
        let wasSignedIn = isSignedIn
        isSignedIn = true
        connectionError = nil
        // Fire only on the signed-out→signed-in edge (this is called on every
        // auth-state sync), so identify + the sign-in-completed funnel event are
        // emitted once per sign-in.
        guard !wasSignedIn else { return }
        if let userID = identityProvider?.currentUserID {
            // Merge the pre-auth anonymous funnel (keyed on the install client id)
            // into the authenticated profile.
            analytics.identify(userId: userID, alias: clientID, properties: [:])
            analytics.setSuperProperties(["is_authenticated": .bool(true)])
        }
        analytics.capture("ios_sign_in_completed", [
            "is_new_user": .bool(false),
        ])
    }

    public func signOut() {
        // Reset analytics identity to anonymous on the signed-in→signed-out edge
        // only (this is called on every unauthenticated auth-state sync).
        if isSignedIn {
            analytics.identify(userId: nil, alias: nil, properties: [:])
            analytics.setSuperProperties(["is_authenticated": .bool(false)])
        }
        suppressNextConnectionOutageEdge = true
        pairingAttemptID = UUID()
        connectionGeneration = UUID()
        isSignedIn = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        connectedHostName = ""
        pairingCode = ""
        terminalInputText = ""
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        // Drop the cached paired Macs so the next signed-in user never sees the
        // previous user's hosts in the switcher.
        pairedMacs = []
        // Reset the in-memory restoring flags; hasKnownPairedMac stays driven by
        // the forget path. On a real account switch the next reconnect's no-mac
        // branch clears the hint. Bump the reconnect generation so any in-flight
        // reconnect is superseded and can't re-set these flags after sign-out.
        storedMacReconnectGeneration &+= 1
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
        replaceRemoteClient(with: nil)
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        reportedViewportSizesByTerminalKey = [:]
        workspaces = PreviewMobileHost.workspaces
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public func resumeForegroundRefresh() {
        startObservingNetworkPathChanges()
        resyncTerminalOutput(reason: "foreground", restartEventStream: true)
    }

}
