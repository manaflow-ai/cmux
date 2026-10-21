import AppKit
import CmuxNextDesign
import Foundation

/// The card's Approvals section (`HomeChiefSettingsView`): "Auto-approve everything the Chief
/// does" with its warning, then "Ask before acting on requests from other devices" and "Ask
/// before acting on what Home shows", greyed out while auto-approve-all is on. Each toggle is one
/// `chief.settings.set` to the brain that answers this Chief; the brain is the one writer and
/// refuses a loosening during remote or another person's work, which the note then says.
extension HomeChiefSettingsView {
    // MARK: Approvals

    func buildApprovals() {
        approvalsHeader.font = Typography.header
        approvalsHeader.ink = .secondary
        approvalsRows.orientation = .vertical
        approvalsRows.alignment = .leading
        approvalsRows.spacing = Metrics.space2
        approvalsRows.setAccessibilityIdentifier("cmux.home.chief.approvals")
        let rows: [(HomeChiefApprovals.Gate, String, String?)] = [
            (.autoApproveAll, HomeEngineStrings.autoApproveAll, HomeEngineStrings.autoApproveAllWarning),
            (.remoteAsk, HomeEngineStrings.remoteAsk, nil),
            (.homeAsk, HomeEngineStrings.homeAsk, nil),
        ]
        for (gate, title, warning) in rows {
            let row = approvalRow(gate, title: title, warning: warning)
            row.translatesAutoresizingMaskIntoConstraints = false
            approvalsRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: approvalsRows.widthAnchor).isActive = true
        }
        addFullWidth(approvalsHeader)
        addFullWidth(approvalsRows)
        stack.setCustomSpacing(Metrics.space4, after: approvalsRows)
        approvalsHeader.isHidden = true
        approvalsRows.isHidden = true
    }

    /// A checkbox and its wrapping title (a click on the title toggles it too), with an optional
    /// caption under the title.
    private func approvalRow(_ gate: HomeChiefApprovals.Gate, title: String, warning: String?) -> NSView {
        let box = ThemedCheckbox(checkboxWithTitle: "", target: self, action: #selector(toggledApproval(_:)))
        box.setAccessibilityLabel(title)
        box.setAccessibilityIdentifier("cmux.home.chief.approval.\(gate.rawValue)")
        box.isEnabled = false
        box.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1
        let width = Self.width - 2 * Self.inset - box.intrinsicContentSize.width - Metrics.space2
        let label = ThemedLabel(wrappingLabelWithString: title)
        label.font = Typography.body
        label.preferredMaxLayoutWidth = width
        label.setAccessibilityElement(false)
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clickedApprovalTitle(_:))))
        text.addArrangedSubview(label)
        if let warning {
            let caption = Self.footnote(warning)
            caption.ink = .secondary
            caption.preferredMaxLayoutWidth = width
            caption.setAccessibilityIdentifier("cmux.home.chief.approval.warning")
            text.addArrangedSubview(caption)
            box.setAccessibilityHelp(warning)
        }
        approvalControls.append((gate, box, label))
        let row = NSStackView(views: [box, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Metrics.space2
        return row
    }

    @objc func toggledApproval(_ sender: NSButton) {
        guard let gate = approvalControls.first(where: { $0.box === sender })?.gate else { return }
        setApproval(gate, on: sender.state == .on)
    }

    @objc func clickedApprovalTitle(_ recognizer: NSClickGestureRecognizer) {
        guard let control = approvalControls.first(where: { $0.title === recognizer.view }), control.box.isEnabled else { return }
        control.box.performClick(nil)
    }

    /// Shows `approvals` (nil hides the section: no answer yet, another Chief, or a brain without
    /// approval settings): each box's state, and the ask gates greyed out under auto-approve-all.
    func showApprovals(_ approvals: HomeChiefApprovals?) {
        shownApprovals = approvals
        let hidden = approvals == nil
        for control in approvalControls {
            let on = approvals?[control.gate] ?? false
            control.box.state = on ? .on : .off
            let editable = approvals?.isEditable(control.gate) ?? false
            control.box.isEnabled = editable
            control.title.ink = editable ? .primary : .tertiary
        }
        guard approvalsRows.isHidden != hidden else { return }
        approvalsHeader.isHidden = hidden
        approvalsRows.isHidden = hidden
        onResize()
    }

    /// Reads the approval settings off the main actor. A brain that does not answer keeps what was
    /// shown, with the boxes off until it does; one without the settings hides the section.
    @discardableResult
    func refreshApprovals() -> Task<Void, Never> {
        let source = source
        let home = muxHome
        // task-owner: one read off the main actor; ends when it is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefApprovals, HomeChiefEngineError> in
                do { return .success(try await source.readApprovals()) } catch let error as HomeChiefEngineError { return .failure(error) } catch {
                    return .failure(.other(String(describing: error)))
                }
            }.value
            guard let self, self.source.isLocal == source.isLocal, self.source.place == source.place, muxHome == home else { return }
            switch result {
            case .success(let approvals): showApprovals(approvals)
            case .failure(.unsupported): showApprovals(nil)
            case .failure: for control in approvalControls { control.box.isEnabled = false }
            }
        }
    }

    /// Turns `gate` on or off on the brain, then shows the settings it answers. A change the brain
    /// refuses (from a turn another person or a paired device started) shows what it keeps again
    /// and says why in the note.
    @discardableResult
    func setApproval(_ gate: HomeChiefApprovals.Gate, on: Bool) -> Task<Void, Never> {
        let source = source
        let home = muxHome
        changeFailed = false
        for control in approvalControls { control.box.isEnabled = false }
        // task-owner: one write off the main actor; ends when its result is shown
        return Task { [weak self] in
            let result = await Task.detached { () async -> Result<HomeChiefApprovals, HomeChiefEngineError> in
                do { return .success(try await source.setApproval(gate, on: on)) } catch let error as HomeChiefEngineError { return .failure(error) } catch {
                    return .failure(.other(String(describing: error)))
                }
            }.value
            guard let self, muxHome == home, self.source.isLocal == source.isLocal, self.source.place == source.place else { return }
            switch result {
            case .success(let approvals):
                if !changeFailed { failure.isHidden = true }
                showApprovals(approvals)
                onResize()
            case .failure(let error):
                showApprovals(shownApprovals)
                note(error.text, kept: true)
            }
        }
    }

    /// The box of `gate` (tests).
    func approvalBox(_ gate: HomeChiefApprovals.Gate) -> NSButton? {
        approvalControls.first { $0.gate == gate }?.box
    }

    /// Whether the Approvals section shows (tests).
    var showsApprovals: Bool { !approvalsRows.isHidden }
}
