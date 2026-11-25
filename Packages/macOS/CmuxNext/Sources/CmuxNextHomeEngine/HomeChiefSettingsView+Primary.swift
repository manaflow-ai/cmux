import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The Primary Chief row (Lawrence 2026-11-02): texts to the cmux line go to the account's
/// primary Chief. The box is on and fixed for the primary one (another Chief is made primary
/// instead); on another Chief, a click makes it primary through ``HomeChiefSettingsView/onMakePrimary``.
extension HomeChiefSettingsView {
    func addPrimaryRow() {
        primaryBox.target = self
        primaryBox.action = #selector(primaryClicked)
        primaryBox.font = Typography.body
        primaryBox.setAccessibilityIdentifier("cmux.home.chief.primary")
        primaryNote.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        addFullWidth(primaryBox)
        addFullWidth(primaryNote)
        stack.setCustomSpacing(Metrics.space4, after: primaryNote)
        setPrimary(nil)
    }

    /// Wires the row to the cloud Chief whose main conversation is `conversation`: a click runs
    /// ``HomeDirectory/setPrimaryChief(_:)``, and the box follows its default flag.
    public func bindPrimary(directory: HomeDirectory, conversation: String) {
        onMakePrimary = { [weak directory] in
            guard let directory, let record = directory.chiefs.first(where: { $0.mainConversation == conversation }) else {
                return HomeEngineStrings.primaryUnknown
            }
            return await directory.setPrimaryChief(record.id)
        }
        primaryWatch?.cancel()
        // task-owner: this view (a rebind cancels it; it ends at the first change after the card is released); event-driven (Observation).
        primaryWatch = Task { [weak self] in
            for await primary in ObservationStream({ directory.chiefs.first(where: { $0.mainConversation == conversation })?.isDefault }) {
                guard let self else { return }  // the card is gone: the watch ends
                setPrimary(primary)
            }
        }
    }

    /// Shows whether this Chief is primary; nil hides the row (a Chief with no account record).
    public func setPrimary(_ isPrimary: Bool?) {
        let hidden = isPrimary == nil
        let changed = primaryBox.isHidden != hidden || (primaryBox.state == .on) != (isPrimary == true)
        primaryBox.isHidden = hidden
        primaryNote.isHidden = hidden
        primaryBox.state = isPrimary == true ? .on : .off
        primaryBox.isEnabled = isPrimary == false
        if changed { onResize() }
    }

    @objc func primaryClicked() {
        primaryBox.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let reason = await onMakePrimary() {
                setPrimary(false)
                note(reason, kept: false)
            } else {
                setPrimary(true)
            }
        }
    }
}
