import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Key event handling and translation
extension GhosttyNSView {
    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        let phaseTotalStart = ProcessInfo.processInfo.systemUptime
        var ensureSurfaceMs: Double = 0
        var dismissNotificationMs: Double = 0
        var keyboardCopyModeMs: Double = 0
        var interpretMs: Double = 0
        var syncPreeditMs: Double = 0
        var ghosttySendMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "terminal.keyDown.phase",
                totalMs: totalMs,
                event: event,
                thresholdMs: 1.0,
                parts: [
                    ("ensureSurfaceMs", ensureSurfaceMs),
                    ("dismissNotificationMs", dismissNotificationMs),
                    ("keyboardCopyModeMs", keyboardCopyModeMs),
                    ("interpretMs", interpretMs),
                    ("syncPreeditMs", syncPreeditMs),
                    ("ghosttySendMs", ghosttySendMs),
                ],
                extra: "marked=\(hasMarkedText() ? 1 : 0)"
            )
            CmuxTypingTiming.logDuration(path: "terminal.keyDown", startedAt: typingTimingStart, event: event)
        }
        let ensureSurfaceStart = ProcessInfo.processInfo.systemUptime
#endif
        guard let surface = ensureSurfaceReadyForInput() else {
            requestInputRecoveryAfterSurfaceMiss(reason: "keyDown.missingSurface")
#if DEBUG
            ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
            super.keyDown(with: event)
            return
        }
        recordDirectAgentHibernationTerminalInput()
#if DEBUG
        ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
        if let mode = RightSidebarMode.modeShortcut(for: event), let window, AppDelegate.shared?.shouldRouteRightSidebarModeShortcut(in: window) == true {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
            return
        }
        if let terminalSurface {
#if DEBUG
            let dismissNotificationStart = ProcessInfo.processInfo.systemUptime
#endif
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
#if DEBUG
            dismissNotificationMs = (ProcessInfo.processInfo.systemUptime - dismissNotificationStart) * 1000.0
#endif
        }
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if !cmuxFindEventIsPlainEscape(event) { endFindEscapeSuppression() }
        if shouldConsumeSuppressedFindEscape(event) { return }
        if cmuxFindEventIsPlainEscape(event), !hasMarkedText(), let terminalSurface, terminalSurface.searchState != nil {
            terminalSurface.searchState = nil
            beginFindEscapeSuppression(); return
        }
#if DEBUG
        let keyboardCopyModeStart = ProcessInfo.processInfo.systemUptime
#endif
        if handleKeyboardCopyModeIfNeeded(event, surface: surface) {
#if DEBUG
            keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
            keyboardCopyModeConsumedKeyUps.insert(event.keyCode)
            return
        }
#if DEBUG
        keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
#if DEBUG
        recordKeyLatency(path: "keyDown", event: event)
#endif

#if DEBUG
        cmuxWriteChildExitProbe(
            [
                "probeKeyDownCharsHex": cmuxScalarHex(event.characters),
                "probeKeyDownCharsIgnoringHex": cmuxScalarHex(event.charactersIgnoringModifiers),
                "probeKeyDownKeyCode": String(event.keyCode),
                "probeKeyDownModsRaw": String(event.modifierFlags.rawValue),
                "probeKeyDownSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeKeyDownCount": 1]
        )
#endif

        // Fast path for control-modified terminal input (for example Ctrl+D).
        //
        // These keys are terminal control input, not text composition, so we bypass
        // AppKit text interpretation and send a single deterministic Ghostty key event.
        // This avoids intermittent drops after rapid split close/reparent transitions.
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

            let text = (event.charactersIgnoringModifiers ?? event.characters ?? "")
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                handled = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ctrlGhosttySend",
                    event: event
                )
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                handled = ghostty_surface_key(surface, keyEvent)
                #endif
            } else {
                #if DEBUG
                let sendTimingStart = CmuxTypingTiming.start()
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                #endif
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
                #if DEBUG
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "terminal.keyDown.ctrlGhosttySend",
                    startedAt: sendTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
                #endif
            }
#if DEBUG
            cmuxDebugLog(
                "key.ctrl path=ghostty surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "handled=\(handled ? 1 : 0) keyCode=\(event.keyCode) chars=\(cmuxScalarHex(event.characters)) " +
                "ign=\(cmuxScalarHex(event.charactersIgnoringModifiers)) mods=\(event.modifierFlags.rawValue)"
            )
#endif
            // If Ghostty handled the key (action/encoding), we're done.
            // If not (e.g. `ignore` keybind), fall through to interpretKeyEvents
            // so the IME gets a chance to process this event.
            if handled { return }
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }
        let textInputEvent = textInputInterpretationEvent(
            original: event,
            translated: translationEvent
        )

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let markedStateBefore = (markedText.string, markedSelectedRange)

        // Capture the keyboard layout ID before interpretation so the IME
        // forwarding decision uses the source that saw this key.
        let keyboardIdBefore = KeyboardLayout.id

        // Let the input system handle the event (for IME, dead keys, etc.)
#if DEBUG
        let interpretTimingStart = CmuxTypingTiming.start()
        let interpretPhaseStart = ProcessInfo.processInfo.systemUptime
#endif
#if DEBUG
        if let debugTextInputEventHandler = Self.debugTextInputEventHandler {
            let handled = debugTextInputEventHandler(self, textInputEvent)
            if !handled {
                interpretKeyEvents([textInputEvent])
            }
        } else {
            interpretKeyEvents([textInputEvent])
        }
#else
        interpretKeyEvents([textInputEvent])
#endif
#if DEBUG
        interpretMs = (ProcessInfo.processInfo.systemUptime - interpretPhaseStart) * 1000.0
        CmuxTypingTiming.logDuration(
            path: "terminal.keyDown.interpretKeyEvents",
            startedAt: interpretTimingStart,
            event: event
        )
#endif

        // If the keyboard layout changed, an input method grabbed the event.
        // Sync preedit and return without sending the key to Ghostty.
        if !markedTextBefore, let kbBefore = keyboardIdBefore, kbBefore != KeyboardLayout.id {
            imeConsumedKeyUps.insert(event.keyCode)
#if DEBUG
            let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
            syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
            syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif
            return
        }

        // Sync preedit so Ghostty can render the IME composition overlay.
#if DEBUG
        let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
        syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
        syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif

        let accumulatedText = keyTextAccumulator ?? []
        if shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: markedStateBefore,
            after: (markedText.string, markedSelectedRange),
            accumulatedText: accumulatedText,
            event: textInputEvent,
            inputSourceId: keyboardIdBefore
        ) {
            imeConsumedKeyUps.insert(event.keyCode)
            return
        }

        // A forwarded keyDown owns its keyUp. Clear any stale IME suppression
        // entry left by an earlier suppressed repeat for the same physical key.
        imeConsumedKeyUps.remove(event.keyCode)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Treat cleared preedit as composing too, so a composing Backspace cancels
        // composition without deleting the preceding terminal input.
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        // Use accumulated text from insertText (for IME), or compute text for key
        if !accumulatedText.isEmpty {
            // Accumulated text comes from insertText (IME composition result).
            // These never have "composing" set to true because these are the
            // result of a composition.
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        _ = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.accumulatedGhosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        _ = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.accumulatedGhosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.accumulatedGhosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            }

            if shouldSendCommittedIMEConfirmKey(
                event: textInputEvent,
                markedTextBefore: markedTextBefore
            ) {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
#if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.accumulatedConfirmGhosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
#else
                _ = ghostty_surface_key(surface, keyEvent)
#endif
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            let suppressShiftSpaceFallbackText =
                shouldSuppressShiftSpaceFallbackText(
                    event: translationEvent,
                    markedTextBefore: markedTextBefore
                )
            let suppressComposingFallbackText = keyEvent.composing
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text),
                   !suppressShiftSpaceFallbackText,
                   !suppressComposingFallbackText {
                    var handled = false
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        handled = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.ghosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        handled = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
                    if handled {
                        notePotentialDeferredNumpadIMECommit(text: text, event: event)
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.ghosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "handled=\(handled ? 1 : 0) textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.ghosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ghosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                _ = ghostty_surface_key(surface, keyEvent)
                #endif
            }
        }

        // Rendering is driven by Ghostty's wakeups/renderer.
    }

    @discardableResult
    func sendGhosttyKey(_ surface: ghostty_surface_t, _ keyEvent: ghostty_input_key_s) -> Bool {
#if DEBUG
        Self.debugGhosttySurfaceKeyEventObserver?(keyEvent)
#endif
        return ghostty_surface_key(surface, keyEvent)
    }

#if DEBUG
    @discardableResult
    private func sendTimedGhosttyKey(
        _ surface: ghostty_surface_t,
        _ keyEvent: ghostty_input_key_s,
        path: String,
        event: NSEvent? = nil,
        extra: String? = nil
    ) -> Bool {
        let timingStart = CmuxTypingTiming.start()
        let handled = sendGhosttyKey(surface, keyEvent)
        let baseExtra = "handled=\(handled ? 1 : 0)"
        let mergedExtra: String
        if let extra, !extra.isEmpty {
            mergedExtra = "\(baseExtra) \(extra)"
        } else {
            mergedExtra = baseExtra
        }
        CmuxTypingTiming.logDuration(path: path, startedAt: timingStart, event: event, extra: mergedExtra)
        return handled
    }
#endif

    override func keyUp(with event: NSEvent) {
        guard let surface = ensureSurfaceReadyForInput() else {
            super.keyUp(with: event)
            return
        }
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            endFindEscapeSuppression()
            return
        }
        if event.keyCode == 53 {
            endFindEscapeSuppression()
        }

        if keyboardCopyModeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }
        if imeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }

        // Build release events from the same translation path as keyDown so
        // consumers that depend on precise key identity (for example Space
        // hold/release flows) receive consistent metadata.
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = sendGhosttyKey(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        if !hasMarkedText(),
           let action = cmuxGhosttyModifierActionForFlagsChanged(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue
           ) {
            // `flagsChanged` carries modifier-only state, not textual key input.
            // Building this via `ghosttyKeyEvent(for:surface:)` would fall through
            // to `unshiftedCodepointFromEvent`, which probes AppKit character APIs
            // that are not safe for modifier-only events.
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = 0
            _ = sendGhosttyKey(surface, keyEvent)
        }

        let selectionActive = ghostty_surface_has_selection(surface)
        let suppressCommandPathHover = event.modifierFlags.contains(.command) && selectionActive
        // Refresh ghostty's mouse position so quicklook_word uses current coordinates
        // when Cmd is pressed while the pointer is stationary.
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
#if DEBUG
        if event.modifierFlags.contains(.command) || selectionActive {
            runtimeDebugLog(
                hypothesisID: "h1",
                name: "flags_changed",
                expected: "selection active should suppress cmd-hover",
                actual: suppressCommandPathHover ? "suppressed" : "forwarded",
                data: [
                    "flags": debugModifierString(event.modifierFlags),
                    "selection_active": selectionActive,
                    "point_x": eventPoint.x,
                    "point_y": eventPoint.y,
                    "resolved_point_x": point.x,
                    "resolved_point_y": point.y
                ]
            )
        }
#endif
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    func hoverModsFromFlags(
        _ flags: NSEvent.ModifierFlags,
        suppressCommandPathHover: Bool
    ) -> ghostty_input_mods_e {
        let effectiveFlags = suppressCommandPathHover ? flags.subtracting(.command) : flags
#if DEBUG
        if suppressCommandPathHover, flags.contains(.command) {
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"
            ) { payload in
                payload["suppressed_command_hover_count"] = (payload["suppressed_command_hover_count"] as? Int ?? 0) + 1
            }
        }
#endif
        return modsFromFlags(effectiveFlags)
    }

    func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    func beginFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = true
    }

    private func endFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = false
    }

    private func shouldConsumeSuppressedFindEscape(_ event: NSEvent) -> Bool {
        isFindEscapeSuppressionArmed && cmuxFindEventIsPlainEscape(event)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        if let layoutChars = KeyboardLayout.character(forKeyCode: event.keyCode),
           layoutChars.count == 1,
           let layoutScalar = layoutChars.unicodeScalars.first,
           layoutScalar.value >= 0x20,
           !(layoutScalar.value >= 0xF700 && layoutScalar.value <= 0xF8FF) {
            return layoutScalar.value
        }

        guard let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// If AppKit consumed Shift+Space for IME/input-source switching, interpretKeyEvents
    /// can return without insertText and without a detectable layout ID change.
    /// In that case we must not synthesize a literal space fallback.
    func shouldSuppressShiftSpaceFallbackText(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedText.length == 0 else { return false }
        return true
    }

    private func shouldSendCommittedIMEConfirmKey(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard markedTextBefore, markedText.length == 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        // Korean IME: Enter commits the syllable AND executes the command (single step).
        // Japanese/Chinese IME: Enter only confirms the conversion; a second Enter executes.
        // Only send the extra Return key for Korean input sources.
        guard let sourceId = KeyboardLayout.id else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }

    func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            let name: String
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                name = String(data: data, encoding: .utf8) ?? ""
            } else {
                name = ""
            }
            keyTables.append(name)
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }

        terminalSurface?.hostedView.syncKeyStateIndicator(text: currentKeyStateIndicatorText)
    }

    // MARK: - Mouse Handling

    #if DEBUG
    func debugModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        [
            flags.contains(.command) ? "cmd" : nil,
            flags.contains(.shift) ? "shift" : nil,
            flags.contains(.control) ? "ctrl" : nil,
            flags.contains(.option) ? "opt" : nil,
        ].compactMap { $0 }.joined(separator: "+")
    }

    func runtimeDebugLog(
        hypothesisID: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        var payload = data
        payload["surface_id"] = terminalSurface?.id.uuidString ?? "nil"
        payload["word_path_hover_active"] = wordPathHoverActive
        CmuxRuntimeDebugCapture.logIfConfigured(
            hypothesisID: hypothesisID,
            source: "GhosttyNSView.\(name)",
            name: name,
            expected: expected,
            actual: actual,
            data: payload
        )
    }

    func runtimeDebugResolutionPayload(_ resolution: WordPathResolution?) -> [String: Any] {
        guard let resolution else {
            return [
                "resolution_source": "none",
                "resolved_path_basename": "",
                "raw_token": ""
            ]
        }

        return [
            "resolution_source": resolution.source.rawValue,
            "resolved_path_basename": URL(fileURLWithPath: resolution.path).lastPathComponent,
            "raw_token": resolution.rawToken
        ]
    }
    #endif

}
