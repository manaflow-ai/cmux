import AppKit
import CmuxSimulator

extension SimulatorRemoteSurfaceView {
    override func mouseDown(with event: NSEvent) {
        guard isPointerInputEnabled else { return }
        beginPointerInteraction(with: event, source: .surface)
    }

    func beginPointerInteraction(
        with event: NSEvent,
        source: SimulatorPointerEntrySource
    ) {
        let location = convert(event.locationInWindow, from: nil)
        if source == .surface {
            onRequestPanelFocus?()
            window?.makeFirstResponder(self)
        }
        if source == .surface,
            let display,
            let button = chrome?.button(
                at: location,
                in: bounds,
                orientation: display.orientation
            )
        {
            pendingPointerEntry = nil
            stageHaloPointerActive = false
            activeChromeButton = button
            send(chromeButtonInput.press(button))
            needsDisplay = true
            return
        }
        guard let point = normalizedPoint(for: event) else {
            guard pointerEntryCaptureRect.contains(location) else { return }
            let flags = event.modifierFlags
            pendingPointerEntry = SimulatorPendingPointerEntry(
                previousLocation: location,
                optionPinch: flags.contains(.option),
                parallelPan: flags.contains(.shift),
                source: source
            )
            stageHaloPointerActive = false
            return
        }
        pendingPointerEntry = nil
        if source == .stageHalo {
            stageHaloPointerActive = true
            onRequestPanelFocus?()
            window?.makeFirstResponder(self)
        }
        let flags = event.modifierFlags
        send(
            input.pointerBegan(
                at: point,
                optionPinch: flags.contains(.option),
                parallelPan: flags.contains(.shift)
            ))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPointerInputEnabled else { return }
        if let button = activeChromeButton {
            let location = convert(event.locationInWindow, from: nil)
            if let chrome, let display,
                !chrome.contains(
                    location,
                    button: button,
                    in: bounds,
                    orientation: display.orientation
                )
            {
                send(chromeButtonInput.release(button))
                activeChromeButton = nil
                needsDisplay = true
            }
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        if input.activePointer == nil, var pendingPointerEntry {
            guard let entry = simulatorPointerEntry(
                from: pendingPointerEntry.previousLocation,
                to: location,
                displayRect: displayRect
            ) else {
                pendingPointerEntry.previousLocation = location
                self.pendingPointerEntry = pendingPointerEntry
                return
            }
            guard let entryPoint = normalizedSimulatorPoint(
                location: entry.location,
                displayRect: displayRect,
                clamped: true
            ), let point = normalizedPoint(for: event, clamped: true) else { return }
            let source = pendingPointerEntry.source
            self.pendingPointerEntry = nil
            if source == .stageHalo {
                stageHaloPointerActive = true
                onRequestPanelFocus?()
                window?.makeFirstResponder(self)
            }
            send(input.pointerBegan(
                at: entryPoint,
                optionPinch: pendingPointerEntry.optionPinch,
                parallelPan: pendingPointerEntry.parallelPan,
                edge: entry.edge
            ))
            if point != entryPoint {
                send(input.pointerMoved(to: point))
            }
            return
        }
        guard let point = normalizedPoint(for: event, clamped: true) else { return }
        send(input.pointerMoved(to: point))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPointerInputEnabled else { return }
        if let button = activeChromeButton {
            send(chromeButtonInput.release(button))
            activeChromeButton = nil
            stageHaloPointerActive = false
            needsDisplay = true
            return
        }
        if pendingPointerEntry != nil, input.activePointer == nil {
            pendingPointerEntry = nil
            stageHaloPointerActive = false
            return
        }
        let point = normalizedPoint(for: event, clamped: true) ?? input.activePointer
        stageHaloPointerActive = false
        guard let point else { return }
        send(input.pointerEnded(at: point))
    }
}
