import Foundation

extension BrowserPanel {
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
        guard reactGrabActivationIntent else { return true }
        let confirmed = await requestReactGrabActiveAndWait(
            false,
            reason: "\(reason).deactivateReactGrab"
        )
        if !confirmed {
#if DEBUG
            cmuxDebugLog("browser.picker.deactivateReactGrab.failed")
#endif
            designModeController.presentError(
                String(
                    localized: "browser.designMode.error.stopReactGrab",
                    defaultValue: "React Grab could not close. Reload the page and try again."
                )
            )
            return false
        }
        return true
    }
}
