import AppKit
import CmuxNextDictation
import Foundation

// User-facing text of the agent pane host. The page's own text is in the
// TypeScript pane.

extension AgentPaneModel {
    /// Tab strip title of an agent tab before the page reports a session title.
    public static var tabTitle: String {
        String(localized: "agentPane.tab.title", defaultValue: "Agent", bundle: .module)
    }

    /// The page's file.open was refused or failed.
    static var openFileFailedMessage: String {
        String(localized: "agentPane.error.openFile", defaultValue: "The file could not be opened.", bundle: .module)
    }

    /// The page's browser.open (a turn's local web page) was refused or failed.
    static var openPreviewFailedMessage: String {
        String(localized: "agentPane.error.openPreview", defaultValue: "The page could not be opened.", bundle: .module)
    }

    /// The system screen capture could not start, or ended with an error and wrote no image.
    static var captureFailedMessage: String {
        String(localized: "agentPane.error.capture", defaultValue: "The screen capture failed.", bundle: .module)
    }

    /// The host's acpmux socket refused a page frame or could not connect (AgentPaneTransport).
    static var transportFailedMessage: String {
        String(localized: "agentPane.error.transport", defaultValue: "The app refused the agent connection.", bundle: .module)
    }

    /// A git read of the changes view failed or has no session host.
    static var gitFailedMessage: String {
        String(localized: "agentPane.error.git", defaultValue: "The changes could not be read.", bundle: .module)
    }

    /// A commit or push of the changes view failed or has no session host.
    static var gitWriteFailedMessage: String {
        String(localized: "agentPane.error.gitWrite", defaultValue: "The git command could not be completed.", bundle: .module)
    }

    /// Shell mode's `shell.run` came without a key press or click in the pane.
    static var shellGestureMessage: String {
        String(localized: "agentPane.shell.gestureRequired", defaultValue: "Not run", bundle: .module)
    }

    /// Why shell mode's command did not run, or was lost.
    /// `shell.complete` ran past its deadline (`shell.timed_out`).
    static var shellCompletionTimedOutMessage: String {
        String(localized: "agentPane.shell.completionTimedOut", defaultValue: "Completion timed out", bundle: .module)
    }

    static func shellFailureMessage(_ error: any Error) -> String {
        switch error as? AgentPaneShell.Failure {
        case .tooMany:
            String(localized: "agentPane.shell.tooMany", defaultValue: "Too many commands running", bundle: .module)
        case .folderMissing:
            String(localized: "agentPane.shell.folderMissing", defaultValue: "Folder not found", bundle: .module)
        case .unknownRun:
            String(localized: "agentPane.shell.unknownRun", defaultValue: "Output unavailable", bundle: .module)
        case .spawnFailed, nil:
            String(localized: "agentPane.shell.spawnFailed", defaultValue: "Could not start", bundle: .module)
        }
    }
}

extension AgentPaneView {
    /// The sheet that confirms a mode in which the agent acts without asking first.
    static var confirmModeTitle: String {
        String(localized: "agentPane.confirmMode.title", defaultValue: "Let the agent act without asking?", bundle: .module)
    }

    /// The sheet for a config option that is not a mode. `%1$@` is the option's display name and `%2$@` its display value.
    static var confirmOptionMessage: String {
        String(localized: "agentPane.confirmOption.message",
               defaultValue: "Change %1$@ to %2$@? Paired devices could then run actions without asking.", bundle: .module)
    }

    /// The display name for the non-mode setting that controls paired-device actions.
    static var confirmFastModeName: String {
        String(localized: "agentPane.confirmOption.fastMode", defaultValue: "Fast mode", bundle: .module)
    }

    static var confirmOptionOn: String {
        String(localized: "agentPane.confirmOption.on", defaultValue: "On", bundle: .module)
    }

    static var confirmOptionOff: String {
        String(localized: "agentPane.confirmOption.off", defaultValue: "Off", bundle: .module)
    }

    static var confirmModeButton: String {
        String(localized: "agentPane.confirmMode.switch", defaultValue: "Switch Mode", bundle: .module)
    }

    /// Shown when the pane's page crashed (it never reloads by itself; the notice offers Reload).
    static var crashedMessage: String {
        String(localized: "agentPane.crashed.message", defaultValue: "The agent pane crashed.", bundle: .module)
    }

    /// Shown when automation would open the inspector without an explicit focus request.
    static var inspectorNeedsFocus: String {
        String(localized: "agentPane.inspector.needsFocus", defaultValue: "Opening the ACP inspector requires focus.", bundle: .module)
    }

    /// Shown when automation would open Session Info without an explicit focus request.
    static var sessionInfoNeedsFocus: String {
        String(localized: "agentPane.sessionInfo.needsFocus", defaultValue: "Opening Session Info requires focus.", bundle: .module)
    }

    /// Why a page command's palette row (``AgentPageCommand``, its title) is greyed out: the focused
    /// chat does not offer it now.
    static func pageCommandUnavailable(_ title: String) -> String {
        String(format: String(localized: "agentPane.pageCommand.unavailable", defaultValue: "%@ isn't available in this chat.",
                              bundle: .module), title)
    }

    /// A greyed palette row's subtitle for a page command the focused chat does not offer now: the
    /// row already shows its title, so the subtitle does not repeat it.
    static var pageCommandUnavailableHere: String {
        String(localized: "agentPane.pageCommand.unavailableHere", defaultValue: "Not available in this chat.", bundle: .module)
    }

    /// Shown when automation would run a page command (its title) without an explicit focus request.
    static func pageCommandNeedsFocus(_ title: String) -> String {
        String(format: String(localized: "agentPane.pageCommand.needsFocus", defaultValue: "%@ requires focus.", bundle: .module), title)
    }

    /// Shown when Toggle Session Info runs with Session Info turned off in Settings.
    static var sessionInfoOff: String {
        String(localized: "agentPane.sessionInfo.off", defaultValue: "Session Info is turned off in Settings.", bundle: .module)
    }

    /// cx-0q7o: an allow went to an agent daemon on another machine that holds no key of this
    /// app for that run (not started by this app, or restarted since), so it refuses the allow.
    static func remoteApprovalsOffTitle(_ machine: String) -> String {
        String(format: String(localized: "agentPane.remoteApprovals.off.title", defaultValue: "Remote approvals are off on %@",
                              bundle: .module), machine)
    }

    static func remoteApprovalsOffDetail(_ machine: String) -> String {
        String(format: String(localized: "agentPane.remoteApprovals.off.detail",
                              defaultValue: "Approvals from cmux are off for the agent daemon on %@. Restart turns them on.",
                              bundle: .module), machine)
    }

    static var remoteApprovalsRestart: String {
        String(localized: "agentPane.remoteApprovals.restart", defaultValue: "Restart with approvals", bundle: .module)
    }

    /// The machine's name when the chat's route names none (a peer of this Mac's agent daemon).
    static var remoteApprovalsThisMachine: String {
        String(localized: "agentPane.remoteApprovals.thisMachine", defaultValue: "the other machine", bundle: .module)
    }

    /// Peer-route approvals: a peer of this Mac's agent daemon has not enrolled this Mac, so it
    /// refused this Mac's signed one-time allow.
    static func peerApprovalsOffTitle(_ peer: String) -> String {
        String(format: String(localized: "agentPane.peerApprovals.off.title", defaultValue: "Enroll this Mac on %@ to allow from here",
                              bundle: .module), peer)
    }

    static var peerApprovalsOffDetail: String {
        String(localized: "agentPane.peerApprovals.off.detail",
               defaultValue: "That machine counts this Mac's one-time Allow only after this Mac is enrolled there. The key never leaves this Mac.",
               bundle: .module)
    }

    static var peerApprovalsEnroll: String {
        String(localized: "agentPane.peerApprovals.enroll", defaultValue: "Enroll this Mac", bundle: .module)
    }

    static func peerApprovalsEnrollFailed(_ peer: String, _ reason: String) -> String {
        String(format: String(localized: "agentPane.peerApprovals.enrollFailed", defaultValue: "Could not enroll this Mac on %@: %@",
                              bundle: .module), peer, reason)
    }

    /// An always-allow (or an answer with notes) for a peer's prompt: only a one-time allow counts.
    static var peerApprovalsOnceOnly: String {
        String(localized: "agentPane.peerApprovals.onceOnly.title", defaultValue: "Only a one-time Allow works from this Mac",
               bundle: .module)
    }

    static func remoteApprovalsRestartFailed(_ machine: String, _ failure: AgentPaneRemoteApprovals.Failure) -> String {
        let reason: String
        switch failure {
        case .noRandomness:
            reason = String(localized: "agentPane.remoteApprovals.failure.noRandomness", defaultValue: "this Mac could not make a key",
                            bundle: .module)
        case .daemonTookNoKey(let line):
            reason = line ?? String(localized: "agentPane.remoteApprovals.failure.noKey",
                                    defaultValue: "the new agent daemon did not take the key", bundle: .module)
        case .keyNotHeld:
            reason = String(localized: "agentPane.remoteApprovals.failure.notHeld",
                            defaultValue: "the agent daemon that answers does not hold this app's key", bundle: .module)
        case .daemonTooOld:
            reason = String(localized: "agentPane.remoteApprovals.failure.tooOld",
                            defaultValue: "the agent daemon there is too old for approvals from cmux. Update the machine, then try again",
                            bundle: .module)
        case .machineNotRunning:
            reason = String(localized: "agentPane.remoteApprovals.failure.notRunning",
                            defaultValue: "the machine is not running", bundle: .module)
        case .notSingleOwner:
            reason = String(localized: "agentPane.remoteApprovals.failure.notOwner",
                            defaultValue: "approvals from cmux work only on a Cloud machine that you alone own", bundle: .module)
        case .failed(let message):
            reason = message
        }
        return String(format: String(localized: "agentPane.remoteApprovals.restartFailed",
                                     defaultValue: "Could not restart the agent daemon on %@: %@", bundle: .module), machine, reason)
    }

    /// Shown when the pane runs on another cmux install's acpmux (NIGHTLY and Release share
    /// `~/.acpmux`): this app cannot allow that daemon's requests (cx-fcaq).
    static var otherInstallMessage: String {
        String(localized: "agentPane.otherInstall.message",
               defaultValue: "This chat runs on another cmux install's agent service. Approve its requests in that app.",
               bundle: .module)
    }

    static var reloadTitle: String {
        String(localized: "agentPane.crashed.reload", defaultValue: "Reload", bundle: .module)
    }
}

extension AgentPaneHostError {
    /// What the page shows for `error`; anything but a host error reads as a
    /// timeout.
    static func userMessage(for error: any Error) -> String {
        // A host's own localized refusal (a remote machine's start refusal) is said as it is.
        if let refusal = error as? any AgentPaneHostRefusal { return refusal.userMessage }
        return switch error as? AgentPaneHostError {
        case .acpmuxNotFound:
            String(
                format: String(localized: "agentPane.error.notInstalled", defaultValue: "acpmux was not found. Install it on your PATH or in one of these folders: %@.", bundle: .module),
                AcpmuxEnvironment.installDirectories.joined(separator: ", ")
            )
        case .daemonFailed(let logPath, let cause):
            if let because = cause.userText {
                String(format: String(localized: "agentPane.error.daemonFailedBecause", defaultValue: "cmux cannot reach acpmux: %1$@. Its log is at %2$@.", bundle: .module), because, logPath)
            } else {
                String(format: String(localized: "agentPane.error.daemonFailed", defaultValue: "acpmux did not start. Its log is at %@.", bundle: .module), logPath)
            }
        case .daemonRestarting:
            String(localized: "agentPane.error.daemonRestarting", defaultValue: "acpmux is restarting on the new version. This chat connects when it is back.", bundle: .module)
        case .daemonStopped:
            String(localized: "agentPane.error.daemonStopped", defaultValue: "acpmux stopped.", bundle: .module)
        case .chiefStopped:
            String(localized: "agentPane.error.chiefStopped", defaultValue: "The Chief is not running. Reopen cmux and open Home to start it.", bundle: .module)
        case .chiefStarting:
            String(localized: "agentPane.error.chiefStarting", defaultValue: "The Chief is starting. This chat connects when it is up.", bundle: .module)
        case .daemonRefused(let holder?, _, _, _, _):
            String(format: String(localized: "agentPane.error.daemonHeldByOtherBuild", defaultValue: "acpmux belongs to %@, and this build may not use it. Quit that app, then try again.", bundle: .module), holder)
        case .daemonRefused(_, _, _, _, _):
            String(localized: "agentPane.error.daemonRefused", defaultValue: "Another acpmux service is using this socket. It will reconnect when that service is ready.", bundle: .module)
        case .timedOut, nil:
            String(localized: "agentPane.error.timedOut", defaultValue: "acpmux did not answer in time.", bundle: .module)
        }
    }
}

extension AgentPaneDictation {
    static func deniedMessage(_ permission: DictationPermission) -> String {
        switch permission {
        case .microphone:
            String(localized: "agentPane.dictation.microphoneDenied", defaultValue: "Dictation needs microphone access. Turn it on for cmux in System Settings.", bundle: .module)
        case .speechRecognition:
            String(localized: "agentPane.dictation.speechDenied", defaultValue: "Dictation in this language needs speech recognition. Turn it on for cmux in System Settings.", bundle: .module)
        }
    }

    static var openSettingsTitle: String {
        String(localized: "agentPane.dictation.openSettings", defaultValue: "Open System Settings", bundle: .module)
    }

    static func failureMessage(_ failure: DictationFailure) -> String {
        switch failure {
        case .onDeviceRecognitionUnavailable:
            String(localized: "agentPane.dictation.languageUnavailable", defaultValue: "On-device dictation is not available for this language.", bundle: .module)
        case .modelDownloadFailed:
            String(localized: "agentPane.dictation.modelDownloadFailed", defaultValue: "The speech model could not be downloaded. Try again when you are online.", bundle: .module)
        case .audioCaptureFailed:
            String(localized: "agentPane.dictation.noMicrophone", defaultValue: "No microphone is available.", bundle: .module)
        case .microphoneAccessDenied, .speechRecognitionAccessDenied, .transcriptionFailed:
            String(localized: "agentPane.dictation.failed", defaultValue: "Dictation stopped unexpectedly.", bundle: .module)
        }
    }
}

extension AgentPaneLoadingView {
    /// The pane's loading state, read by VoiceOver while the page loads and acpmux starts.
    static var label: String {
        String(localized: "agentPane.loading", defaultValue: "Loading agent chat", bundle: .module)
    }
}
