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

    /// The host's acpmux socket refused a page frame or could not connect (AgentPaneTransport).
    static var transportFailedMessage: String {
        String(localized: "agentPane.error.transport", defaultValue: "The app refused the agent connection.", bundle: .module)
    }

    /// A git read of the changes view failed or has no session host.
    static var gitFailedMessage: String {
        String(localized: "agentPane.error.git", defaultValue: "The changes could not be read.", bundle: .module)
    }

    /// Shell mode's `shell.run` came without a key press or click in the pane.
    static var shellGestureMessage: String {
        String(localized: "agentPane.shell.gestureRequired", defaultValue: "Not run", bundle: .module)
    }

    /// Why shell mode's command did not run, or was lost.
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
    /// The sheet that offers to add a folder the agent asked for outside the workspace's folders.
    static var addRootTitle: String {
        String(localized: "agentPane.addRoot.title", defaultValue: "Add this folder to the workspace?", bundle: .module)
    }

    /// `%@` is the folder's path.
    static var addRootMessage: String {
        String(localized: "agentPane.addRoot.message", defaultValue: "The agent asked to work in %@, which is outside this workspace's folders.", bundle: .module)
    }

    /// The sheet that confirms a mode in which the agent acts without asking first.
    static var confirmModeTitle: String {
        String(localized: "agentPane.confirmMode.title", defaultValue: "Let the agent act without asking?", bundle: .module)
    }

    /// `%@` is the mode's id.
    static var confirmModeMessage: String {
        String(localized: "agentPane.confirmMode.message", defaultValue: "This chat would switch to %@, a mode in which the agent does not ask before it acts.", bundle: .module)
    }

    /// The sheet for a config option that is not a mode. `%1$@` is the option's id, `%2$@` its value.
    static var confirmOptionMessage: String {
        String(localized: "agentPane.confirmOption.message",
               defaultValue: "Change %1$@ to %2$@? Paired devices could then run actions without asking.", bundle: .module)
    }

    static var confirmModeButton: String {
        String(localized: "agentPane.confirmMode.switch", defaultValue: "Switch Mode", bundle: .module)
    }

    static var addRootButton: String {
        String(localized: "agentPane.addRoot.add", defaultValue: "Add Folder", bundle: .module)
    }

    /// Shown when the pane's page keeps crashing and no longer reloads itself.
    static var crashedMessage: String {
        String(localized: "agentPane.crashed.message", defaultValue: "The agent pane crashed repeatedly.", bundle: .module)
    }

    static var reloadTitle: String {
        String(localized: "agentPane.crashed.reload", defaultValue: "Reload", bundle: .module)
    }
}

extension AgentPaneHostError {
    /// What the page shows for `error`; anything but a host error reads as a
    /// timeout.
    static func userMessage(for error: any Error) -> String {
        switch error as? AgentPaneHostError {
        case .acpmuxNotFound:
            String(
                format: String(localized: "agentPane.error.notInstalled", defaultValue: "acpmux was not found. Install it on your PATH or in one of these folders: %@.", bundle: .module),
                AcpmuxEnvironment.installDirectories.joined(separator: ", ")
            )
        case .daemonFailed(let logPath):
            String(format: String(localized: "agentPane.error.daemonFailed", defaultValue: "acpmux did not start. Its log is at %@.", bundle: .module), logPath)
        case .daemonStopped:
            String(localized: "agentPane.error.daemonStopped", defaultValue: "acpmux is not running. Open a new agent chat to start it.", bundle: .module)
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
