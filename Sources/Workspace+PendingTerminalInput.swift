import AppKit
import CmuxWorkspaces

extension Workspace {

    /// Delivers config-driven startup input (`Workspace+CustomLayout.swift`) once
    /// the terminal surface is ready, or immediately when it already is.
    func sendInputWhenReady(
        _ text: String,
        to panel: TerminalPanel,
        reason: WorkspacePendingTerminalInputReason = .configurationCommand
    ) {
        if panel.surface.surface != nil {
            panel.sendInput(text)
            return
        }

        let timeout = reason.timeout
        let panelId = panel.id
        let registration = WorkspacePendingTerminalInputObserver()

        registration.observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { [weak self, registration] _ in
            Task { @MainActor [weak self, registration] in
                guard
                    let self,
                    self.hasPendingTerminalInputObserver(registration, forPanelId: panelId)
                else {
                    return
                }

                self.removePendingTerminalInputObserver(registration, forPanelId: panelId)
                if let panel = self.panels[panelId] as? TerminalPanel {
                    panel.sendInput(text)
                }
            }
        }
        pendingTerminalInputObserversByPanelId[panelId, default: []].append(registration)
        panel.surface.requestBackgroundSurfaceStartIfNeeded()

        guard let timeout else { return }
        // A one-shot DispatchSourceTimer bridges this synchronous notification
        // lifecycle to the genuine terminal-readiness deadline.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self, weak registration] in
            guard let self,
                  let registration,
                  self.hasPendingTerminalInputObserver(registration, forPanelId: panelId) else {
                return
            }

            self.removePendingTerminalInputObserver(registration, forPanelId: panelId)
            #if DEBUG
            NSLog("[CmuxConfig] surface not ready after 3s, dropping command (%d chars)", text.count)
            #endif
        }
        registration.timeoutTimer = timer
        timer.resume()
    }

    private func hasPendingTerminalInputObserver(
        _ registration: WorkspacePendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) -> Bool {
        pendingTerminalInputObserversByPanelId[panelId]?.contains {
            $0 === registration
        } == true
    }

    private func removePendingTerminalInputObserver(
        _ registration: WorkspacePendingTerminalInputObserver,
        forPanelId panelId: UUID
    ) {
        if let observer = registration.observer {
            NotificationCenter.default.removeObserver(observer)
            registration.observer = nil
        }
        registration.timeoutTimer?.cancel()
        registration.timeoutTimer = nil
        pendingTerminalInputObserversByPanelId[panelId]?.removeAll {
            $0 === registration
        }
        if pendingTerminalInputObserversByPanelId[panelId]?.isEmpty == true {
            pendingTerminalInputObserversByPanelId.removeValue(forKey: panelId)
        }
    }

    func removePendingTerminalInputObservers(forPanelId panelId: UUID) {
        guard let observers = pendingTerminalInputObserversByPanelId.removeValue(forKey: panelId) else {
            return
        }
        for registration in observers {
            if let observer = registration.observer {
                NotificationCenter.default.removeObserver(observer)
                registration.observer = nil
            }
            registration.timeoutTimer?.cancel()
            registration.timeoutTimer = nil
        }
    }

}
