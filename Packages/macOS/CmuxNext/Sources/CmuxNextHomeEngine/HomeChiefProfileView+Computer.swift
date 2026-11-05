import AppKit

/// The Computer tab's gate and control (Chief computer take-over): the note that stands in for a
/// screen, the control bar under a live one, and the person's input while they hold control.
extension HomeChiefProfileView {
    /// The note for `gate` (nil: the screen shows).
    func showGate(_ gate: Gate?) {
        switch gate {
        case .paywall:
            gateLabel.stringValue = HomeEngineStrings.computerPaywall(name())
            gateButton.title = HomeEngineStrings.computerUpgrade
            gateButton.isHidden = false
        case .needsCloudChief:
            // The panel has the Computer Use picker right under the note; the page has none.
            gateLabel.stringValue = settings == nil ? HomeEngineStrings.computerNeedsCloudChief(name())
                : HomeEngineStrings.computerNeedsCloudOrMachine(name())
            gateButton.title = HomeEngineStrings.computerMove
            gateButton.isHidden = false
        case .notSetUp:
            gateLabel.stringValue = HomeEngineStrings.computerNotSetUp(name())
            gateButton.isHidden = true
        case .machine:
            gateLabel.stringValue = HomeEngineStrings.computerOnMachine(name())
            gateButton.isHidden = true
        case nil:
            break
        }
    }

    /// Whether the control bar belongs under what the tab shows: a Cloud Chief's computer on screen,
    /// or the Cloud machine a Chief of this Mac uses.
    var showsControl: Bool {
        shownGate == nil || shownGate == .machine
    }

    /// The bar shows under a computer it can change; the screen takes the person's input only while
    /// they hold control of a computer that takes it this way (a Cloud Chief's own; a Cloud machine's
    /// desktop opens on its own with Take Over).
    func followControl() {
        let shown = control != nil && showsControl
        controlBar.isHidden = !shown || controlBar.shown == nil
        let takesInput = shown && shownGate == nil && controlBar.personDrives && control?.send != nil && isOpen
        if takesInput, computer.screen.input == nil {
            computer.screen.input = { [weak self] in self?.send($0) }
        } else if !takesInput, computer.screen.input != nil {
            computer.screen.input = nil
        }
    }

    /// Sends `input` after the ones before it, in order. A send the computer refuses (the Chief took
    /// it back, the computer is gone) says so in the bar.
    func send(_ input: HomeChiefComputerInput) {
        guard let send = control?.send else { return }
        let previous = sending
        // task-owner: one input of the person's, after the one before; cancelled when the profile closes
        sending = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await send(input)
            } catch {
                guard !Task.isCancelled else { return }
                self?.controlBar.sendFailed()
            }
        }
    }
}
