import Foundation

struct SimulatorInputReleaseProof: Sendable {
    var pointerRevision: UInt64?
    var keyRevisions: [UInt32: UInt64] = [:]
    var buttonRevisions: [SimulatorHIDButtonUsage: UInt64] = [:]

    var isEmpty: Bool {
        pointerRevision == nil && keyRevisions.isEmpty && buttonRevisions.isEmpty
    }
}

extension SimulatorWorkerClient {
    func remember(_ message: SimulatorWorkerInbound) async {
        switch message {
        case .attach:
            lastAttachment = message
        case let .resize(geometry):
            lastGeometry = geometry
        case let .pointer(event):
            rememberPointer(event)
        case let .key(event):
            rememberKey(event)
        case let .keySequence(events):
            for event in events { rememberKey(event) }
        case let .scrollWheel(event):
            rememberScrollWheel(event)
        case let .typeText(requestID, sequence):
            pendingTextInputUsages[requestID] = Set(sequence.events.map(\.usage))
        case let .configureCamera(requestID, configuration):
            cameraRequestConfigurations[requestID] = configuration
        case let .switchCameraSource(requestID, configuration):
            cameraSourceSwitchRequests[requestID] = configuration
        case let .setCameraMirror(requestID, mode):
            cameraMirrorRequests[requestID] = mode
        case let .hidButton(event):
            rememberHIDButton(event)
        case let .button(button):
            if let usage = button.recoveryHIDUsage {
                unprovenConvenienceButtonUsages.insert(usage)
            }
        case let .interactiveAction(requestID, action):
            pendingInteractiveRequestIdentifiers.insert(requestID)
            rememberInteractiveAction(action)
        case .releaseInputs:
            rememberReleaseOfAllInputs()
        default:
            break
        }
    }

    func captureInputReleaseProof(sequence: UInt64) {
        guard !unprovenInputRelease.isEmpty else { return }
        inputReleaseProofs[sequence] = unprovenInputRelease
        unprovenInputRelease = SimulatorInputReleaseProof()
    }

    func applyInputReleaseProofs(through sequence: UInt64) {
        for proofSequence in inputReleaseProofs.keys.filter({ $0 <= sequence }).sorted() {
            guard let proof = inputReleaseProofs.removeValue(forKey: proofSequence) else {
                continue
            }
            if let revision = proof.pointerRevision,
               pointerStateRevision == revision {
                activePointer = nil
                pointerStateRevision = nil
            }
            for (usage, revision) in proof.keyRevisions
            where keyStateRevisions[usage] == revision {
                heldKeyUsages.remove(usage)
                keyStateRevisions.removeValue(forKey: usage)
            }
            for (button, revision) in proof.buttonRevisions
            where buttonStateRevisions[button] == revision {
                heldButtonUsages.remove(button)
                buttonStateRevisions.removeValue(forKey: button)
            }
        }
    }

    func resetHeldInputState() {
        activePointer = nil
        activeScrollIdentifier = nil
        pointerStateRevision = nil
        heldKeyUsages.removeAll()
        keyStateRevisions.removeAll()
        pendingTextInputUsages.removeAll()
        pendingInteractiveRequestIdentifiers.removeAll()
        deferredMessages.removeAll()
        probeNeededAfterTextInput = false
        heldButtonUsages.removeAll()
        buttonStateRevisions.removeAll()
        unprovenInputRelease = SimulatorInputReleaseProof()
        inputReleaseProofs.removeAll()
        unprovenConvenienceButtonUsages.removeAll()
        convenienceButtonProofs.removeAll()
    }

    func retainPotentialKeyUsage(_ usage: UInt32) {
        guard !heldKeyUsages.contains(usage) else { return }
        heldKeyUsages.insert(usage)
        keyStateRevisions[usage] = nextInputRevision()
    }

    func retainPotentialHIDButton(_ button: SimulatorHIDButtonUsage) {
        guard !heldButtonUsages.contains(button) else { return }
        heldButtonUsages.insert(button)
        buttonStateRevisions[button] = nextInputRevision()
    }

    private func rememberPointer(_ event: SimulatorPointerEvent) {
        activeScrollIdentifier = nil
        let revision = nextInputRevision()
        pointerStateRevision = revision
        switch event.phase {
        case .began, .moved:
            activePointer = event
            unprovenInputRelease.pointerRevision = nil
        case .ended, .cancelled:
            if activePointer == nil { activePointer = event }
            unprovenInputRelease.pointerRevision = revision
        }
    }

    private func rememberScrollWheel(_ event: SimulatorScrollWheelEvent) {
        let revision = nextInputRevision()
        activeScrollIdentifier = event.id
        pointerStateRevision = revision
        activePointer = SimulatorPointerEvent(
            phase: .moved,
            primary: SimulatorPoint(
                x: min(max(event.anchor.x + event.deltaX, 0), 1),
                y: min(max(event.anchor.y + event.deltaY, 0), 1)
            )
        )
        unprovenInputRelease.pointerRevision = nil
    }

    private func rememberKey(_ event: SimulatorKeyEvent) {
        let revision = nextInputRevision()
        keyStateRevisions[event.usage] = revision
        switch event.phase {
        case .down:
            heldKeyUsages.insert(event.usage)
            unprovenInputRelease.keyRevisions.removeValue(forKey: event.usage)
        case .up:
            guard heldKeyUsages.contains(event.usage) else {
                keyStateRevisions.removeValue(forKey: event.usage)
                return
            }
            unprovenInputRelease.keyRevisions[event.usage] = revision
        }
    }

    private func rememberHIDButton(_ event: SimulatorHIDButtonEvent) {
        let revision = nextInputRevision()
        buttonStateRevisions[event.button] = revision
        switch event.phase {
        case .down:
            heldButtonUsages.insert(event.button)
            unprovenInputRelease.buttonRevisions.removeValue(forKey: event.button)
        case .up:
            guard heldButtonUsages.contains(event.button) else {
                buttonStateRevisions.removeValue(forKey: event.button)
                return
            }
            unprovenInputRelease.buttonRevisions[event.button] = revision
        }
    }

    private func rememberReleaseOfAllInputs() {
        if activePointer != nil {
            let revision = nextInputRevision()
            pointerStateRevision = revision
            unprovenInputRelease.pointerRevision = revision
        }
        for usage in heldKeyUsages {
            let revision = nextInputRevision()
            keyStateRevisions[usage] = revision
            unprovenInputRelease.keyRevisions[usage] = revision
        }
        for button in heldButtonUsages {
            let revision = nextInputRevision()
            buttonStateRevisions[button] = revision
            unprovenInputRelease.buttonRevisions[button] = revision
        }
    }

    private func rememberInteractiveAction(_ action: SimulatorInteractiveAction) {
        switch action {
        case let .gesture(events):
            guard let event = events.first(where: {
                $0.phase == .began || $0.phase == .moved
            }) else { return }
            rememberPointer(event)
        case let .hardwareButton(button):
            if let usage = button.recoveryHIDUsage {
                retainPotentialHIDButton(usage)
            }
        case .rotate, .coreAnimation, .memoryWarning:
            break
        }
    }

    private func nextInputRevision() -> UInt64 {
        let revision = nextInputStateRevision
        nextInputStateRevision &+= 1
        return revision
    }
}
