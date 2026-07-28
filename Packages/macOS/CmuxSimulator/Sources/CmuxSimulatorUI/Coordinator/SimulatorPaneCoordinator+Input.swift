import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Validates a complete US-keyboard string, then queues one ordered worker message.
    @discardableResult
    public func typeText(_ text: String) -> Result<Int, SimulatorTextInputSubmissionError> {
        beginTypeText(text, completion: nil).map(\.characterCount)
    }

    /// Queues one text sequence and reports its correlated worker completion.
    @discardableResult
    public func beginTypeText(
        _ text: String,
        completion: (@MainActor @Sendable (Bool) -> Void)?
    ) -> Result<SimulatorTextInputSubmission, SimulatorTextInputSubmissionError> {
        let sequence: SimulatorTextInputSequence
        do {
            sequence = try SimulatorUSKeyboardTextEncoder().encode(text)
        } catch let error as SimulatorTextInputEncodingError {
            let submissionError = SimulatorTextInputSubmissionError.encoding(error)
            controlFailure = submissionError.failure
            return .failure(submissionError)
        } catch {
            let submissionError = SimulatorTextInputSubmissionError.deliveryUnavailable
            controlFailure = submissionError.failure
            return .failure(submissionError)
        }

        guard capabilities.contains(.keyboard), status == .streaming else {
            let error = SimulatorTextInputSubmissionError.inputUnavailable
            controlFailure = error.failure
            return .failure(error)
        }
        let requestID = UUID()
        if let completion { textInputCompletions[requestID] = completion }
        guard enqueue(.typeText(requestID: requestID, sequence: sequence)) else {
            textInputCompletions.removeValue(forKey: requestID)
            let error = SimulatorTextInputSubmissionError.deliveryUnavailable
            controlFailure = error.failure
            return .failure(error)
        }
        controlFailure = nil
        return .success(SimulatorTextInputSubmission(
            requestIdentifier: requestID,
            characterCount: sequence.characterCount,
            completionTimeoutSeconds: sequence.completionTimeoutSeconds
        ))
    }

    /// Cancels accepted text before it can outlive its socket request deadline.
    public func cancelTextInput(requestID: UUID) {
        guard let completion = textInputCompletions.removeValue(forKey: requestID) else { return }
        cancelledTextInputRequestIDs.insert(requestID)
        status = .connecting
        let previousRecoveryTask = outgoingRecoveryTask
        outgoingRecoveryGeneration &+= 1
        outgoingRecoveryTask = Task { @MainActor [weak self, client] in
            _ = await previousRecoveryTask?.value
            await client.invalidateWorker()
            if self?.status == .connecting { self?.status = .workerCrashed }
            self?.cancelledTextInputRequestIDs.remove(requestID)
            completion(false)
        }
    }

    func failPendingTextInputCompletions() {
        let completions = textInputCompletions.values
        textInputCompletions.removeAll()
        for completion in completions { completion(false) }
    }

    /// Updates pane geometry while suppressing identical resize messages.
    /// - Parameter geometry: The measured pane size and backing scale.
    public func updateGeometry(_ geometry: SimulatorSurfaceGeometry) {
        guard geometry.width > 0, geometry.height > 0, geometry != self.geometry else { return }
        self.geometry = geometry
        enqueue(.resize(geometry))
    }

    /// Sends a software-keyboard toggle to the active device.
    public func toggleSoftwareKeyboard() {
        enqueue(.toggleSoftwareKeyboard)
    }

    /// Toggles native pointer and keyboard capture. Escape releases capture.
    public func togglePointerCapture() {
        let mode: SimulatorHIDCaptureMode = hidCaptureMode == .pointerAndKeyboard
            ? .none
            : .pointerAndKeyboard
        enqueue(.setHIDCapture(mode))
    }

    /// Toggles keyboard-only capture for iPadOS shortcuts.
    public func toggleKeyboardCapture() {
        let mode: SimulatorHIDCaptureMode = hidCaptureMode == .keyboard ? .none : .keyboard
        enqueue(.setHIDCapture(mode))
    }

    /// Sends one hardware or system button press.
    /// - Parameter button: The button to press.
    public func press(_ button: SimulatorHardwareButton) {
        enqueue(.button(button))
    }

    /// Rotates the active device counter-clockwise.
    public func rotateLeft() {
        let orientation = (display?.orientation ?? .portrait).rotatedLeft
        enqueue(.rotate(orientation))
    }

    /// Rotates the active device clockwise.
    public func rotateRight() {
        let current = display?.orientation ?? .portrait
        enqueue(.rotate(current.rotatedLeft.rotatedLeft.rotatedLeft))
    }

    /// Rotates the Apple Watch Digital Crown by a raw delta.
    /// - Parameter delta: Positive or negative crown motion.
    public func rotateDigitalCrown(by delta: Double) {
        enqueue(.digitalCrown(delta))
    }

    /// Delivers a simulated memory warning to the foreground app.
    public func sendMemoryWarning() {
        enqueue(.memoryWarning)
    }

    /// Enables or disables a Core Animation diagnostic.
    /// - Parameters:
    ///   - diagnostic: The diagnostic overlay or visualization.
    ///   - enabled: Whether the diagnostic should be active.
    public func setCoreAnimationDiagnostic(_ diagnostic: SimulatorCADiagnostic, enabled: Bool) {
        enqueue(.coreAnimationDiagnostic(diagnostic, enabled: enabled))
    }

    /// Requests a fresh accessibility snapshot.
    public func refreshAccessibility() async {
        _ = try? await perform(.readAccessibility)
    }

    /// Requests metadata for the current foreground application.
    public func refreshForegroundApplication() async {
        _ = try? await perform(.readForegroundApplication)
    }

    /// Reloads the foreground React Native or Expo JavaScript bundle.
    public func reloadReactNative() async {
        _ = try? await perform(.reloadReactNative)
    }

    /// Shows one accessibility element frame over the live display.
    /// - Parameter node: The accessibility element to highlight.
    public func highlightAccessibilityNode(_ node: SimulatorAccessibilityNode) async {
        guard (try? await perform(.setAccessibilityHighlight(
            nodeID: node.id,
            frame: node.frame
        ))) != nil else { return }
        highlightedAccessibilityNodeID = node.id
    }

    /// Clears the accessibility element frame overlay.
    public func clearAccessibilityHighlight() async {
        guard (try? await perform(.setAccessibilityHighlight(nodeID: nil, frame: nil))) != nil else { return }
        highlightedAccessibilityNodeID = nil
    }

    /// Sends a deterministic swipe sequence without timer-based synchronization.
    /// - Parameters:
    ///   - start: The first normalized touch point.
    ///   - end: The final normalized touch point.
    ///   - edge: The system edge associated with the gesture.
    public func swipe(from start: SimulatorPoint, to end: SimulatorPoint, edge: SimulatorEdge = .none) {
        enqueue(.pointer(SimulatorPointerEvent(phase: .began, primary: start, edge: edge)))
        for step in 1...6 {
            let progress = Double(step) / 7
            let point = SimulatorPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            enqueue(.pointer(SimulatorPointerEvent(phase: .moved, primary: point, edge: edge)))
        }
        enqueue(.pointer(SimulatorPointerEvent(phase: .ended, primary: end, edge: edge)))
    }

    /// Releases touch and keyboard state held by the host pane.
    public func releaseInputs() {
        enqueue(.releaseInputs)
    }

    /// Requests keyboard focus for the live AppKit Simulator surface.
    public func focus() {
        focusRequestGeneration &+= 1
    }

    /// Updates panel activity and guarantees input cleanup when deactivated.
    /// - Parameter isActive: Whether the panel is the active input target.
    public func setActive(_ isActive: Bool) {
        if isActive {
            focus()
        } else {
            releaseInputs()
        }
    }
}
