import Foundation

extension TerminalPanel {
    func retireFromUIForDeferredClose() {
        retireFromUIForClose()
    }

    private func retireFromUIForClose() {
        guard !isClosingPanel else { return }
        isClosingPanel = true
        discardTextBoxContentForClose()
        surface.beginPortalCloseLifecycle(reason: "panel.close")
#if DEBUG
        let frame = String(format: "%.1fx%.1f", hostedView.frame.width, hostedView.frame.height)
        let bounds = String(format: "%.1fx%.1f", hostedView.bounds.width, hostedView.bounds.height)
        cmuxDebugLog(
            "surface.panel.close.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) runtimeSurface=\(surface.surface != nil ? 1 : 0) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        )
#endif
        unfocus()
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
#if DEBUG
        cmuxDebugLog(
            "surface.panel.close.end panel=\(id.uuidString.prefix(5)) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
    }

    func close() {
        retireFromUIForClose()
        guard !didTeardownRuntimeForClose else { return }
        didTeardownRuntimeForClose = true
        surface.teardownSurface()
    }
}
