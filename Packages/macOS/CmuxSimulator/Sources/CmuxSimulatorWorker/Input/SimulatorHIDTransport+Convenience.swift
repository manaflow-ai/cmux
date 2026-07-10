import CmuxSimulator

enum SimulatorConvenienceButton: Hashable, Sendable {
    case modern(page: UInt32, usage: UInt32)
    case legacy(eventSource: Int32)
    case arbitrary(page: UInt32, usage: UInt32)

    var sortKey: (UInt32, UInt32, UInt32) {
        switch self {
        case let .modern(page, usage): (0, page, usage)
        case let .legacy(eventSource): (1, UInt32(bitPattern: eventSource), 0)
        case let .arbitrary(page, usage): (2, page, usage)
        }
    }
}

extension SimulatorHIDTransport {
    /// Sends React Native's registered Command-R key command. Every successful
    /// down is explicitly unwound if a later phase fails.
    @discardableResult
    func reloadReactNative() -> Bool {
        let commandUsage: UInt32 = 0xE3
        let rUsage: UInt32 = 0x15
        guard !heldKeys.contains(commandUsage), !heldKeys.contains(rUsage) else { return false }
        var pressed: [UInt32] = []
        let sequence = [
            SimulatorKeyEvent(usage: commandUsage, phase: .down),
            SimulatorKeyEvent(usage: rUsage, phase: .down),
            SimulatorKeyEvent(usage: rUsage, phase: .up),
            SimulatorKeyEvent(usage: commandUsage, phase: .up),
        ]
        for event in sequence {
            guard send(event) else {
                unwindKeys(&pressed)
                return false
            }
            switch event.phase {
            case .down:
                pressed.append(event.usage)
            case .up:
                pressed.removeAll { $0 == event.usage }
            }
        }
        return true
    }

    @discardableResult
    func press(_ button: SimulatorHardwareButton) async -> Bool {
        switch SimulatorHardwareButtonMapping(button) {
        case let .legacy(eventSource):
            let mapped = modernUsage(forLegacyEventSource: eventSource)
            let token: SimulatorConvenienceButton
            if let mapped, modernTransport != nil || convenienceSenderOverride != nil {
                token = .modern(page: mapped.page, usage: mapped.usage)
            } else {
                token = .legacy(eventSource: eventSource)
            }
            let duration: Duration = eventSource == 0x400002
                ? .milliseconds(300)
                : .milliseconds(50)
            return await pressConvenience(token, duration: duration)
        case let .arbitrary(page, usage):
            let token: SimulatorConvenienceButton = modernTransport != nil
                || convenienceSenderOverride != nil
                ? .modern(page: page, usage: usage)
                : .arbitrary(page: page, usage: usage)
            return await pressConvenience(token, duration: .milliseconds(50))
        case .swipeHome:
            return await sendSystemGesture(endY: 0.30, holdsAtEnd: false)
        case .appSwitcher:
            return await sendSystemGesture(endY: 0.42, holdsAtEnd: true)
        }
    }

    @discardableResult
    func toggleSoftwareKeyboard() -> Bool {
        let token = SimulatorConvenienceButton.legacy(eventSource: 0x3F0)
        guard sendConvenience(token, down: true) else { return false }
        heldConvenienceButtons.insert(token)
        guard sendConvenience(token, down: false) else { return false }
        heldConvenienceButtons.remove(token)
        return true
    }

    @discardableResult
    func releaseInputs() -> Bool {
        var succeeded = true
        if let lastPointerEvent {
            let cancelled = send(SimulatorPointerEvent(
                phase: .cancelled,
                primary: lastPointerEvent.primary,
                secondary: lastPointerEvent.secondary,
                edge: lastPointerEvent.edge
            ))
            succeeded = cancelled && succeeded
        }
        for usage in heldKeys.sorted() {
            let released = send(SimulatorKeyEvent(usage: usage, phase: .up))
            succeeded = released && succeeded
        }
        for button in heldButtons.buttons.sorted(by: {
            ($0.page, $0.usage) < ($1.page, $1.usage)
        }) {
            let released = send(SimulatorHIDButtonEvent(button: button, phase: .up))
            succeeded = released && succeeded
        }
        for token in heldConvenienceButtons.sorted(by: { $0.sortKey < $1.sortKey }) {
            if sendConvenience(token, down: false) {
                heldConvenienceButtons.remove(token)
            } else {
                succeeded = false
            }
        }
        return succeeded
    }

    private func pressConvenience(
        _ token: SimulatorConvenienceButton,
        duration: Duration
    ) async -> Bool {
        guard sendConvenience(token, down: true) else { return false }
        heldConvenienceButtons.insert(token)
        do {
            try await sleeper.sleep(for: duration)
        } catch {
            if sendConvenience(token, down: false) {
                heldConvenienceButtons.remove(token)
            }
            return false
        }
        guard sendConvenience(token, down: false) else { return false }
        heldConvenienceButtons.remove(token)
        return true
    }

    private func sendConvenience(_ token: SimulatorConvenienceButton, down: Bool) -> Bool {
        if let convenienceSenderOverride {
            return convenienceSenderOverride(token, down)
        }
        switch token {
        case let .modern(page, usage):
            return modernTransport?.sendButton(page: page, usage: usage, down: down) == true
        case let .legacy(eventSource):
            return sendLegacyButton(eventSource: eventSource, direction: down ? 1 : 2)
        case let .arbitrary(page, usage):
            return sendArbitraryHID(page: page, usage: usage, direction: down ? 1 : 2)
        }
    }

    private func unwindKeys(_ pressed: inout [UInt32]) {
        for usage in pressed.reversed() {
            _ = send(SimulatorKeyEvent(usage: usage, phase: .up))
        }
        pressed.removeAll()
    }

    private func modernUsage(
        forLegacyEventSource eventSource: Int32
    ) -> (page: UInt32, usage: UInt32)? {
        switch eventSource {
        case 0:
            (0x0C, 0x40)
        case 1, 0x0BB8:
            (0x0C, 0x30)
        case 0x400002:
            (0x0C, 0xCF)
        default:
            nil
        }
    }
}
