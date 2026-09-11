import AppKit

extension NSApplication {
    @objc func cmux_accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if Thread.isMainThread, let cache = AppDelegate.shared?.accessibilityWindowCache {
            switch cache.resolve(attribute: attribute, application: self) {
            case .handled(let value):
                return value
            case .passthrough:
                break
            }
        }
        return cmux_accessibilityAttributeValue(attribute)
    }

    @objc func cmux_applicationSendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        if event.type == .keyDown { CmuxTypingTiming.logEventDelay(path: "app.sendEvent", event: event) }
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(path: "app.sendEvent.phase", totalMs: totalMs, event: event, thresholdMs: 1.0, parts: [("dispatchMs", totalMs)])
                CmuxTypingTiming.logDuration(path: "app.sendEvent", startedAt: typingTimingStart, event: event)
            }
        }
#endif
        if event.type == .leftMouseDown,
           AppDelegate.shared?.handleMinimalModeTitlebarDoubleClickMouseDown(event: event) == true {
            return
        }
        if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(
            event,
            preferredWindow: event.window ?? AppDelegate.shared?.shortcutRoutingActiveWindow ?? keyWindow ?? mainWindow
        ) {
            return
        }
        if AppDelegate.shared?.shouldSuppressStaleCmuxMenuShortcut(event: event) == true {
            if AppDelegate.shared?.handleFocusedFileExplorerOpenSelectionShortcut(
                event,
                preferredWindow: event.window ?? keyWindow ?? mainWindow
            ) == true {
#if DEBUG
                cmuxDebugLog("app.sendEvent routed file explorer shortcut before stale cmux menu shortcut")
#endif
                return
            }
            if AppDelegate.shared?.handleConfiguredShortcutKeyEquivalent(event) == true {
#if DEBUG
                cmuxDebugLog("app.sendEvent routed configured shortcut before stale cmux menu shortcut")
#endif
                return
            }
            let responder = event.window?.firstResponder
                ?? AppDelegate.shared?.shortcutRoutingKeyWindow?.firstResponder
                ?? mainWindow?.firstResponder
            if let ghosttyView = responder.cmuxTerminalKeyEquivalentOwningGhosttyView() {
                ghosttyView.keyDown(with: event)
#if DEBUG
                cmuxDebugLog("app.sendEvent suppressed stale cmux menu shortcut and forwarded to terminal")
#endif
            } else {
#if DEBUG
                cmuxDebugLog("app.sendEvent suppressed stale cmux menu shortcut")
#endif
            }
            return
        }
        cmux_applicationSendEvent(event)
    }

    @objc func cmux_sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        if AppDelegate.shared?.handleDetachedInspectorWindowCloseAction(
            action: action,
            target: target,
            sender: sender
        ) == true {
            return true
        }
        return cmux_sendAction(action, to: target, from: sender)
    }
}
