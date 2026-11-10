import AppKit

/// The Computer tab's gate and control (Chief computer take-over): the note that stands in for a
/// screen, the control bar under a live one, and the person's input while they hold control.
extension HomeChiefProfileView {
    /// The note for `gate` (nil: the screen shows).
    func showGate(_ gate: Gate?) {
        gateMoveButton.isHidden = gate != .noComputer
        switch gate {
        case .paywall:
            gateLabel.stringValue = HomeEngineStrings.computerPaywall(name())
            gateButton.title = HomeEngineStrings.computerUpgrade
            gateButton.isHidden = false
        case .needsCloudChief:
            // The popover has the Computer Use picker right under the note; the page has none.
            gateLabel.stringValue = settings == nil ? HomeEngineStrings.computerNeedsCloudChief(name())
                : HomeEngineStrings.computerNeedsCloudOrMachine(name())
            gateButton.title = HomeEngineStrings.computerMove
            gateButton.isHidden = false
        case .noComputer, .notSetUp where onProvision != nil:
            // The person gives the Chief its computer (a Chief of this Mac too, the move beside it); it takes a few
            // minutes, and the status says when it is there.
            showSetUp(making: provisionAsk == .asking || computer.provisioning, failed: computer.provisionFailed)
        case .notSetUp:
            gateLabel.stringValue = computer.provisioning ? HomeEngineStrings.computerProvisioning(name()) : HomeEngineStrings.computerNotSetUp(name())
            gateButton.isHidden = true
        case .machine:
            gateLabel.stringValue = HomeEngineStrings.computerOnMachine(name())
            gateButton.isHidden = true
        case nil:
            break
        }
    }

    /// The Set Up Computer note: being made, why the last ask made nothing, or the offer. A server with no
    /// computers says so with no button, since asking again cannot help.
    private func showSetUp(making: Bool, failed: Bool) {
        let chief = name()
        gateLabel.stringValue = switch provisionAsk {
        case _ where making: HomeEngineStrings.computerProvisioning(chief)
        case .unavailable: HomeEngineStrings.computerNotOnServer
        case .localLimit: HomeEngineStrings.computerLocalLimit
        case .failed: HomeEngineStrings.computerProvisionFailed(chief)
        case .idle, .asking: failed ? HomeEngineStrings.computerProvisionFailed(chief) : HomeEngineStrings.computerProvisionNote(chief)
        }
        gateButton.title = HomeEngineStrings.computerProvision
        gateButton.isHidden = making || provisionAsk == .unavailable
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
        let takesInput = shown && shownGate == nil && tabs.selected == .computer && controlBar.personDrives && !controlBar.givingBack && control?.send != nil && isOpen
        if takesInput {
            inputs.resume()
        } else {
            // Inputs still queued must not reach a computer the person gave back.
            inputs.drop()
        }
        if takesInput, computer.screen.input == nil {
            computer.screen.input = { [weak self] in self?.send($0) }
        } else if !takesInput, computer.screen.input != nil {
            computer.screen.input = nil
        }
    }

    /// Sends `input` after the ones before it, in order (one consumer; inputs queued behind a send
    /// coalesce). A send the computer refuses while the person still drives says so in the bar.
    func send(_ input: HomeChiefComputerInput) {
        inputs.send = control?.send
        inputs.enqueue(input)
    }

    /// Whether Set Up Computer is offered for a Chief of this Mac: its card is here to pick the computer once made.
    var setsUpLocally: Bool {
        onProvision != nil && localComputer() != nil && settings?.source.isLocal == true
    }

    /// Set Up Computer: one ask at a time; the section reads the status again at once so the note follows it.
    /// A Chief of this Mac (``Gate/noComputer``) then uses its new computer for Computer Use (``localComputer``).
    func provision() {
        guard provisionAsk != .asking, let ask = shownGate == .noComputer ? provisionLocally() : onProvision else { return }
        provisionAsk = .asking
        computer.forgetProvisionFailure()
        refresh()
        // task-owner: one Set Up Computer ask; the Cloud service makes the computer in the background
        Task { [weak self] in
            let outcome: ProvisionAsk
            do { try await ask(); outcome = .idle } catch { outcome = Self.outcome(of: error) }
            guard let self else { return }
            provisionAsk = outcome
            if computer.isOpen { computer.open() }
            refresh()
        }
    }

    /// What a failed ask leaves on the note.
    static func outcome(of error: any Error) -> ProvisionAsk {
        switch error as? SetUpRefusal {
        case .localLimit?: .localLimit
        case .unavailable?: .unavailable
        case nil: .failed
        }
    }

    /// The ask for a Chief of this Mac: the Cloud service makes its own computer, then the Chief's card picks it for
    /// Computer Use (engine.json's `computer`), so its `cloud_computer` tool drives it. A pick the brain did not take fails.
    private func provisionLocally() -> (@MainActor () async throws -> Void)? {
        guard let onProvision, let target = localComputer(), let settings else { return nil }
        return {
            try await onProvision()
            guard await settings.attach(target) else { throw CancellationError() }
        }
    }
}
