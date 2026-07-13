import AppKit
import CoreGraphics

extension AppDelegate {
    enum InactiveDisplayTransitionState: Equatable {
        case idle
        case armed(signature: String?)
        case recoveryReady(signature: String?)
    }

    func makeMonitorMemoryLifecycleObservers() -> [NSObjectProtocol] {
        registerDisplayReconfigurationCallbackIfNeeded()
        _ = ScreenLockObserver.shared
        return [
            makeDisplayReconfigurationObserver(),
            makeScreenChangeReconcileObserver(),
            makeScreenParametersObserver(),
            makeWindowScreenObserver(),
        ] + makeInactiveDisplayLifecycleObservers() + makeScreenLockLifecycleObservers()
    }

    private func makeDisplayReconfigurationObserver() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: Self.displayReconfigurationNotification,
            object: self,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isBeginning = note.userInfo?["isBeginning"] as? Bool ?? false
                self.handleDisplayReconfiguration(isBeginning: isBeginning)
            }
        }
    }

    private func makeScreenChangeReconcileObserver() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: Self.screenChangeReconcileNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileMainWindowFramesAfterScreenChange()
            }
        }
    }

    private func makeScreenParametersObserver() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
#if DEBUG
                let names = NSScreen.screens.map(\.localizedName).joined(separator: ", ")
                cmuxDebugLog(
                    "monitorMemory.screenChange displays=\(NSScreen.screens.count) [\(names)]"
                )
#endif
                self?.handleScreenParametersDidChange()
            }
        }
    }

    private func makeWindowScreenObserver() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window = note.object as? NSWindow,
                      self.contextForMainTerminalWindow(window) != nil,
                      self.inactiveDisplayRecoveryIsPending else { return }
                self.scheduleScreenChangeReconcileWhenIdle()
            }
        }
    }

    private func makeInactiveDisplayLifecycleObservers() -> [NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        let inactiveNames = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]
        let recoveryNames = [
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        let inactiveObservers = inactiveNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.beginInactiveDisplayTransition()
                }
            }
        }
        let recoveryObservers = recoveryNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.markInactiveDisplayRecoveryReady()
                }
            }
        }
        return inactiveObservers + recoveryObservers
    }

    private func makeScreenLockLifecycleObservers() -> [NSObjectProtocol] {
        let center = DistributedNotificationCenter.default()
        let locked = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginInactiveDisplayTransition()
            }
        }
        let unlocked = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: true)
            }
        }
        return [locked, unlocked]
    }

    func beginInactiveDisplayTransition(configurationSignature: String? = nil) {
        removeInactiveDisplayRecoveryInteractionMonitor()
        let pinnedSignature: String?
        switch inactiveDisplayTransitionState {
        case .idle:
            pinnedSignature = configurationSignature
                ?? currentDisplayConfigurationSignature()
                ?? lastAppliedConfigurationSignature
            for window in mainWindowsForVisibilityController() {
                captureWindowConfigFrame(window, reason: "inactiveTransition")
            }
        case let .armed(signature),
             let .recoveryReady(signature):
            pinnedSignature = signature
        }
        inactiveDisplayTransitionState = .armed(signature: pinnedSignature)
        beginScreenChangeCaptureSuppression()
    }

    func markInactiveDisplayRecoveryReady(isSessionActiveAndUnlocked: Bool? = nil) {
        let sessionIsReady = isSessionActiveAndUnlocked
            ?? MacPresenceMonitor.consoleSessionActiveAndUnlocked(
                sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any],
                observedScreenLocked: ScreenLockObserver.shared.isLockedObserved
            )
        guard sessionIsReady else { return }
        let signature: String?
        switch inactiveDisplayTransitionState {
        case let .armed(pinnedSignature), let .recoveryReady(pinnedSignature):
            signature = pinnedSignature
        case .idle:
            return
        }
        inactiveDisplayTransitionState = .recoveryReady(signature: signature)
        scheduleScreenChangeReconcileWhenIdle()
        installInactiveDisplayRecoveryInteractionMonitorIfNeeded()
    }

    func inactiveDisplayRecoveryMatches(signature: String) -> Bool {
        guard case let .recoveryReady(pinnedSignature) = inactiveDisplayTransitionState else {
            return false
        }
        return pinnedSignature == signature
    }

    var inactiveDisplayRecoveryIsPending: Bool {
        if case .recoveryReady = inactiveDisplayTransitionState { return true }
        return false
    }

    func updateInactiveDisplayRecoveryAfterReconcile(currentSignature: String) {
        guard case let .recoveryReady(pinnedSignature) = inactiveDisplayTransitionState else {
            return
        }
        guard pinnedSignature == currentSignature else {
            finishInactiveDisplayRecovery()
            return
        }
        inactiveDisplayTransitionState = .recoveryReady(signature: pinnedSignature)
    }

    func installInactiveDisplayRecoveryInteractionMonitorIfNeeded() {
        guard inactiveDisplayRecoveryInteractionMonitor == nil else { return }
        inactiveDisplayRecoveryInteractionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.inactiveDisplayRecoveryIsPending else { return }
                self.finalizeInactiveDisplayRecovery()
            }
            return event
        }
    }

    func removeInactiveDisplayRecoveryInteractionMonitor() {
        guard let monitor = inactiveDisplayRecoveryInteractionMonitor else { return }
        NSEvent.removeMonitor(monitor)
        inactiveDisplayRecoveryInteractionMonitor = nil
    }

    func finalizeInactiveDisplayRecovery() {
        finalizeInactiveDisplayRecovery(
            displays: currentDisplayGeometries(),
            isMirrored: Self.displaysAreMirrored()
        )
    }

    func finalizeInactiveDisplayRecovery(
        displays: (available: [SessionDisplayGeometry], fallback: SessionDisplayGeometry?),
        isMirrored: Bool
    ) {
        guard inactiveDisplayRecoveryIsPending else { return }
        guard !isApplyingSessionRestore, !isTerminatingApp, !displays.available.isEmpty else {
            return
        }
        reconcileMainWindowFramesAfterScreenChange(displays: displays, isMirrored: isMirrored)
        guard inactiveDisplayRecoveryIsPending else { return }
        finishInactiveDisplayRecovery()
    }

    private func finishInactiveDisplayRecovery() {
        inactiveDisplayTransitionState = .idle
        removeInactiveDisplayRecoveryInteractionMonitor()
    }

    nonisolated static func shouldRestoreAfterInactiveDisplayTransition(
        liveFrame: CGRect,
        rememberedDisplay: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry]
    ) -> Bool {
        guard let targetDisplay = display(for: rememberedDisplay, in: availableDisplays),
              let liveDisplay = bestDisplayForFrame(liveFrame, in: availableDisplays) else {
            return false
        }
        return !samePhysicalDisplay(liveDisplay, targetDisplay)
    }

    nonisolated static func samePhysicalDisplay(
        _ lhs: SessionDisplayGeometry,
        _ rhs: SessionDisplayGeometry
    ) -> Bool {
        if let lhsID = lhs.displayID, let rhsID = rhs.displayID {
            return lhsID == rhsID
        }
        if let lhsKey = lhs.stableID, !lhsKey.isEmpty,
           let rhsKey = rhs.stableID, !rhsKey.isEmpty {
            return lhsKey == rhsKey
        }
        return lhs.frame.equalTo(rhs.frame)
    }
}
