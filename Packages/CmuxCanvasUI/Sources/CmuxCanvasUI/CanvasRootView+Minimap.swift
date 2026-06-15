import AppKit

extension CanvasRootView {
    private static let minimapVisibleAlpha: CGFloat = 0.92
    private static let minimapAutoHideDelayNanoseconds: UInt64 = 3_000_000_000

    func updateMinimap(reveal: Bool = false) {
        let visible = canvasRect(fromDocument: scrollView.contentView.documentVisibleRect)
        let focusedPaneID = model.layout.panes.first { pane in
            pane.panelIds.contains { descriptorsByPanelId[$0.rawValue]?.isFocused == true }
        }?.id
        let panes = model.layout.panes.map { pane in
            let frame: CGRect
            if let dragSession, dragSession.paneID == pane.id {
                frame = dragSession.lastFrame
            } else {
                frame = pane.frame.cgRect
            }
            return CanvasMinimapPaneSnapshot(id: pane.id, frame: frame)
        }
        let snapshot = CanvasMinimapSnapshot(
            panes: panes,
            visibleRect: visible,
            focusedPaneID: focusedPaneID
        )
        minimapView.snapshot = snapshot
        if !snapshot.shouldShow {
            resetMinimapVisibility()
        } else if reveal {
            showMinimapTemporarily()
        }
    }

    func resetMinimapVisibility() {
        minimapHideTask?.cancel()
        minimapHideTask = nil
        minimapView.alphaValue = 0
        minimapView.isHidden = true
    }

    private func showMinimapTemporarily() {
        minimapHideTask?.cancel()
        minimapView.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            minimapView.animator().alphaValue = Self.minimapVisibleAlpha
        }

        minimapHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.minimapAutoHideDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.hideMinimap(animated: true)
            }
        }
    }

    private func hideMinimap(animated: Bool) {
        minimapHideTask?.cancel()
        minimapHideTask = nil
        guard !minimapView.isHidden || minimapView.alphaValue != 0 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                minimapView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.minimapView.alphaValue == 0 else { return }
                    self.minimapView.isHidden = true
                }
            })
        } else {
            resetMinimapVisibility()
        }
    }
}
