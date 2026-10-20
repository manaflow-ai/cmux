import AppKit

extension CanvasRootView {
    private static let minimapVisibleAlpha: CGFloat = 0.92
    private static let minimapAutoHideDelay: Duration = .seconds(3)

    func configureMinimap(accessibilityLabel: String, accessibilityHelp: String) {
        minimapView.onCenterChanged = { [weak self] center in
            self?.setViewport(center: center, magnification: nil, notifySettled: false)
        }
        minimapView.onCenterSettled = { [weak self] center in
            self?.setViewport(center: center, magnification: nil, notifySettled: true)
        }
        minimapView.onScrollWheel = { [weak self] event in self?.scrollView.scrollWheel(with: event) }
        minimapView.onInteractionBegan = { [weak self] in self?.holdMinimapVisible() }
        minimapView.onInteractionEnded = { [weak self] in self?.releaseMinimapAfterInteraction() }
        minimapView.accessibilityLabelText = accessibilityLabel
        minimapView.accessibilityHelpText = accessibilityHelp
    }

    func updateMinimap(reveal: Bool = false) {
        guard isWorkspaceVisible else {
            resetMinimapVisibility()
            return
        }
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
        } else if isMinimapInteractionActive {
            holdMinimapVisible()
        } else if reveal {
            showMinimapTemporarily()
        }
    }

    func resetMinimapVisibility() {
        isMinimapInteractionActive = false
        minimapView.resetInteractionState()
        minimapAutoHideScheduler.cancel()
        minimapView.alphaValue = 0
        minimapView.isHidden = true
    }

    func holdMinimapVisible() {
        guard syncMinimapOverlayHost() else {
            resetMinimapVisibility()
            return
        }
        isMinimapInteractionActive = true
        minimapAutoHideScheduler.cancel()
        minimapView.isHidden = false
        minimapView.alphaValue = Self.minimapVisibleAlpha
    }

    func releaseMinimapAfterInteraction() {
        isMinimapInteractionActive = false
        guard minimapView.snapshot.shouldShow else {
            resetMinimapVisibility()
            return
        }
        showMinimapTemporarily()
    }

    private func showMinimapTemporarily() {
        guard syncMinimapOverlayHost() else {
            resetMinimapVisibility()
            return
        }
        let shouldAnimateIn = minimapView.isHidden || minimapView.alphaValue < Self.minimapVisibleAlpha
        minimapView.isHidden = false
        if shouldAnimateIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                minimapView.animator().alphaValue = Self.minimapVisibleAlpha
            }
        } else {
            minimapView.alphaValue = Self.minimapVisibleAlpha
        }
        minimapAutoHideScheduler.schedule { [weak self] in
            self?.hideMinimap(animated: true)
        }
    }

    private func hideMinimap(animated: Bool) {
        minimapAutoHideScheduler.cancel()
        guard !isMinimapInteractionActive else {
            holdMinimapVisible()
            return
        }
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
