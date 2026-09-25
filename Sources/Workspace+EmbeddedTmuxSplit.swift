import AppKit
import Bonsplit
import Foundation

extension Workspace {
    /// An embedded tmux profile has one terminal surface, independent of its transport.
    var usesEmbeddedTmuxSplits: Bool {
        !isRemoteTmuxMirror && !usesSSHTui && remoteConfiguration?.transport == .ssh
            && remoteConfiguration?.terminalProfile.tmuxSessionName != nil
    }

    /// Invalidates requests and presentation when the management connection changes.
    func resetEmbeddedTmuxSplit() {
        embeddedTmuxSplitCompletionTask?.cancel()
        embeddedTmuxSplitCompletionTask = nil
        embeddedTmuxSplits.reset()
        embeddedTmuxSplitError = nil
    }

    /// Shared split owner for shortcuts, the palette, pane menus, and socket callers.
    func requestEmbeddedTmuxSplit(
        from panelID: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool,
        hasLaunchOverrides: Bool
    ) -> TerminalPanelCreationOutcome {
        guard panels[panelID] is TerminalPanel, let configuration = remoteConfiguration else {
            return .failed
        }
        let error: String?
        if hasLaunchOverrides {
            error = String(localized: "remoteTmux.embeddedSplit.options", defaultValue: "This tmux split cannot apply terminal launch overrides. Use an explicit local split for a local command.")
        } else if remoteConnectionState != .connected {
            error = String(localized: "remoteTmux.embeddedSplit.disconnected", defaultValue: "The SSH management connection is unavailable. Reconnect before splitting the remote tmux session.")
        } else if embeddedTmuxSplits.phase == .running {
            error = String(localized: "remoteTmux.embeddedSplit.pending", defaultValue: "A remote tmux split is already pending. Wait for it to finish before creating another.")
        } else {
            error = nil
        }
        if let error {
            embeddedTmuxSplitError = error
            if focus { presentEmbeddedTmuxSplitFailure(error) }
            return .failed
        }
        guard let requestID = embeddedTmuxSplits.start(
            configuration: configuration,
            vertical: orientation == .vertical,
            insertBefore: insertFirst,
            focus: focus
        ) else { return .failed }
        embeddedTmuxSplitCompletionTask?.cancel()
        embeddedTmuxSplitCompletionTask = Task { [weak self, embeddedTmuxSplits] in
            let result = await embeddedTmuxSplits.completion(for: requestID)
            guard !Task.isCancelled, let self, !self.isRetiredFromOwningTabManager else { return }
            self.embeddedTmuxSplitCompletionTask = nil
            guard result == .failed else { return }
            let message = String(localized: "remoteTmux.embeddedSplit.failed", defaultValue: "The remote tmux split could not be confirmed. Check the remote session before trying again; no local pane was created.")
            self.embeddedTmuxSplitError = message
            if focus { self.presentEmbeddedTmuxSplitFailure(message) }
        }
        return .routedToRemote
    }

    /// Background automation exposes failures through status without opening a sheet.
    private func presentEmbeddedTmuxSplitFailure(_ message: String) {
        guard let window = owningTabManager?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "remoteTmux.embeddedSplit.title", defaultValue: "Couldn’t split the remote tmux session")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.beginSheetModal(for: window)
    }

    /// Distinguishes an embedded split from a native mirror and reports its eventual result.
    var embeddedTmuxSplitStatusPayload: [String: Any] {
        [
            "rendering": "embedded",
            "state": embeddedTmuxSplits.phase.rawValue,
            "request_id": embeddedTmuxSplits.requestID?.uuidString ?? NSNull(),
            "pane_id": embeddedTmuxSplits.paneID ?? NSNull(),
            "error": embeddedTmuxSplits.phase == .failed ? (embeddedTmuxSplitError ?? NSNull()) : NSNull(),
            "last_rejection": embeddedTmuxSplits.phase != .failed ? (embeddedTmuxSplitError ?? NSNull()) : NSNull(),
        ]
    }
}
