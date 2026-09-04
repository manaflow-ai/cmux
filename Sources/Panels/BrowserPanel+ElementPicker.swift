import Foundation

extension BrowserPanel {
    /// Starts a browser-chrome Design Mode transition on the panel-owned task.
    /// Keeping the operation here lets lifecycle teardown cancel either the
    /// active chip or overflow-menu action without separate unstructured tasks.
    @discardableResult
    func toggleDesignModeFromBrowserChrome(reason: String) -> Bool {
        guard designModeToolbarToggleTask == nil else { return false }
        designModeToolbarToggleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.designModeToolbarToggleTask = nil }
            guard !Task.isCancelled else { return }
            _ = await self.toggleDesignMode(reason: reason)
        }
        return true
    }

    /// Cancels a toolbar-triggered Design Mode transition during view teardown.
    func cancelDesignModeToolbarToggle() {
        // Keep the handle until the task's defer runs so cancellation cannot
        // overlap a still-unwinding transition with a later toolbar action.
        designModeToolbarToggleTask?.cancel()
    }

    @discardableResult
    func toggleDesignMode(reason: String) async -> Bool {
        await setDesignModeEnabled(!designModeController.isActive, reason: reason)
    }

    @discardableResult
    func setDesignModeEnabled(_ enabled: Bool, reason: String) async -> Bool {
        if enabled, !(await deactivateReactGrabForDesignMode(reason: reason)) {
            return false
        }
        return await designModeController.setEnabled(enabled, reason: reason)
    }

    @discardableResult
    func prepareForReactGrabActivation(reason: String) async -> Bool {
        guard designModeController.protectsFromDiscard else { return true }
        let disabled = await designModeController.setEnabled(
            false,
            reason: "\(reason).deactivateDesignMode"
        )
        if !disabled {
            designModeController.presentError(
                String(
                    localized: "browser.designMode.error.stopForReactGrab",
                    defaultValue: "Design Mode could not close before starting React Grab. Reload the page and try again."
                )
            )
        }
        return disabled
    }

    private func deactivateReactGrabForDesignMode(reason: String) async -> Bool {
        guard isReactGrabActive else { return true }
        do {
            _ = try await designModeController.evaluatePageJavaScript(
                "window.__REACT_GRAB__?.deactivate(); true",
                in: webView
            )
            isReactGrabActive = false
            clearReactGrabRoundTrip(reason: "\(reason).deactivateReactGrab")
            return true
        } catch {
#if DEBUG
            cmuxDebugLog("browser.picker.deactivateReactGrab.failed error=\(String(reflecting: error))")
#endif
            designModeController.presentError(
                String(
                    localized: "browser.designMode.error.stopReactGrab",
                    defaultValue: "React Grab could not close. Reload the page and try again."
                )
            )
            return false
        }
    }
}
