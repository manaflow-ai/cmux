public import AppKit
import CmuxNextActions
import CmuxNextDesign
import Foundation

/// The settings page's cards and their rows (`HomeChiefSettingsView`).
extension HomeChiefSettingsView {
    // MARK: Layout

    func addFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The avatar (a menu changes it) with the name and where the brain runs beside it.
    func identityRow() -> NSView {
        avatarButton.target = self
        avatarButton.action = #selector(showPictureMenu)
        avatarButton.setAccessibilityLabel(HomeEngineStrings.changePicture)
        avatarButton.themedToolTip = HomeEngineStrings.changePicture
        // A picture dropped on the avatar is chosen as Choose Picture… chooses one.
        avatarButton.onDropPicture = { [weak self] in self?.usePicture($0) }
        nameField.target = self
        nameField.action = #selector(renamed)
        // Leaving the field (a click elsewhere, the popover closing) keeps the name, as Return does.
        nameField.cell?.sendsActionOnEndEditing = true
        nameField.setAccessibilityLabel(HomeEngineStrings.name)
        nameField.placeholderString = HomeEngineStrings.name
        nameField.font = Typography.body
        let box = ThemedFieldBox(field: nameField, height: Metrics.controlHeight)
        place.font = Typography.caption
        place.ink = .secondary
        place.lineBreakMode = .byTruncatingTail
        place.stringValue = HomeEngineStrings.runsHere
        hostSwitch.isBordered = false
        hostSwitch.bezelStyle = .inline
        hostSwitch.font = Typography.caption
        hostSwitch.contentTintColor = Palette.litGlyph
        hostSwitch.target = self
        hostSwitch.action = #selector(switchHost)
        hostSwitch.isHidden = true
        hostSwitch.setAccessibilityIdentifier("cmux.home.chief.switchHost")
        let text = NSStackView(views: [box, place, hostSwitch])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1
        text.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        place.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor).isActive = true
        let row = NSStackView(views: [avatarButton, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space3
        // The name takes the rest of the row, not the width of the line under it.
        text.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        return row
    }

    /// The Brain card: Backend (UniiChat's sign-in note under it), Model, Effort and Speed, each
    /// with the line that says what it changes, then when a change applies.
    func buildBrainCard() {
        let rows = [(harness, HomeChiefCardStrings.backend, HomeChiefCardStrings.backendHelp),
                    (model, HomeEngineStrings.model, HomeChiefCardStrings.modelHelp),
                    (effort, HomeEngineStrings.effort, HomeChiefCardStrings.effortHelp),
                    (speed, HomeEngineStrings.speed, HomeChiefCardStrings.speedHelp)]
        for (button, label, help) in rows {
            button.target = self
            button.action = #selector(picked(_:))
            button.font = Typography.body
            button.setAccessibilityLabel(label)
            brainCard.add(HomeChiefSettingsRow(label, control: button, help: help, wrapWidth: Self.innerWidth))
            if button === harness {
                harnessHint.font = Typography.caption
                harnessHint.ink = .secondary
                harnessHint.isHidden = true
                harnessHint.setAccessibilityIdentifier("cmux.home.chief.harnessHint")
                harnessHint.preferredMaxLayoutWidth = Self.innerWidth
                brainCard.add(harnessHint)
            }
        }
        speed.superview?.isHidden = true
        let note = Self.footnote(HomeEngineStrings.nextTurn)
        note.preferredMaxLayoutWidth = Self.innerWidth
        brainCard.add(note)
    }

    /// The Reactions card (a416): whether a tapback the person puts on a Chief message may start a
    /// turn, and the classifier that decides it behind its own closed disclosure
    /// (``HomeChiefReactionRows``).
    func buildReactionsCard() {
        reactionRows.onPick = { [weak self] fields in self?.pick(fields) }
        reactionRows.onResize = { [weak self] in self?.onResize() }
        reactionsCard.add(reactionRows)
    }

    /// The Memory card (this Mac's brain): what the Chief remembers, and Show Memory (the
    /// built-in Memory Inspector, every build).
    func buildMemoryCard() {
        let help = Self.footnote(HomeChiefCardStrings.memoryHelp)
        help.ink = .secondary
        help.preferredMaxLayoutWidth = Self.innerWidth
        memoryCard.add(help)
        let show = HomeChiefLinkButton(title: HomeEngineStrings.showMemory, target: self, action: #selector(showMemory))
        show.setAccessibilityIdentifier("cmux.home.chief.showMemory")
        memoryCard.add(show, fills: false)
    }

    static func footnote(_ text: String) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = Typography.caption
        label.ink = .tertiary
        return label
    }

    /// Adds a row to the Identity card (the Chief's pet, its character): a title at the
    /// leading edge and `control` at the trailing edge.
    public func addAppearanceRow(_ title: String, control: NSView) {
        identityCard.add(HomeChiefSettingsRow(title, control: control, wrapWidth: Self.innerWidth))
        onResize()
    }

    /// The closed disclosure over the diagnostics: a triangle and its title, one click target.
    func diagnosticsRow() -> NSView {
        diagnosticsToggle.setButtonType(.pushOnPushOff)
        diagnosticsToggle.bezelStyle = .disclosure
        diagnosticsToggle.title = ""
        diagnosticsToggle.state = .off
        diagnosticsToggle.target = self
        diagnosticsToggle.action = #selector(toggleDiagnostics)
        diagnosticsToggle.setAccessibilityLabel(HomeEngineStrings.diagnostics)
        let title = HomeChiefLinkButton(title: HomeEngineStrings.diagnostics, target: self, action: #selector(clickDiagnosticsTitle))
        // One control for VoiceOver and Tab: the triangle (named Diagnostics, with its expanded
        // state); the title is a larger click target for the pointer only. A button is never an
        // element itself, its cell is, so the cell is the one to hide.
        title.cell?.setAccessibilityElement(false)
        title.refusesFirstResponder = true
        title.ink = .secondary
        title.textFont = Typography.header
        let row = NSStackView(views: [diagnosticsToggle, title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space1
        return row
    }

    /// The Diagnostics card: the last turn and Show Traces, then the closed disclosure's recent
    /// replies and where the brain runs.
    func buildDiagnostics() {
        diagnosticsCard.add(lastTurn)
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = Metrics.space2
        diagnostics.isHidden = true
        for label in [replies, brain] {
            label.font = Typography.caption
            label.ink = .secondary
            label.preferredMaxLayoutWidth = Self.innerWidth
            label.translatesAutoresizingMaskIntoConstraints = false
            diagnostics.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: diagnostics.widthAnchor).isActive = true
        }
        replies.isHidden = true
        brain.stringValue = String(format: HomeEngineStrings.brainFormat, muxHome.path)
        diagnosticsCard.add(diagnostics)
        let traces = HomeChiefLinkButton(title: HomeEngineStrings.openTraces, target: self, action: #selector(openTraces))
        traces.setAccessibilityIdentifier("cmux.home.chief.openTraces")
        links.addArrangedSubview(traces)
        links.orientation = .horizontal
        links.spacing = Metrics.space4
        diagnosticsCard.add(links)
        localViews = [brain, links, memoryCard]
    }

    @objc func clickDiagnosticsTitle() {
        diagnosticsToggle.state = diagnosticsToggle.state == .on ? .off : .on
        toggleDiagnostics()
    }

    @objc func toggleDiagnostics() {
        diagnostics.isHidden = diagnosticsToggle.state != .on
        onResize()
    }

    /// Whether the diagnostics show (tests).
    var showsDiagnostics: Bool { !diagnostics.isHidden }
}
