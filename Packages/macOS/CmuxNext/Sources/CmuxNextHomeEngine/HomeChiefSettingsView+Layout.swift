public import AppKit
import CmuxNextActions
import CmuxNextDesign
import Foundation

/// The settings card's sections and rows (`HomeChiefSettingsView`).
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
        avatarButton.onDropPicture = { [weak self] in self?.editPicture($0) }
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

    /// A section's title: secondary ink, the header weight.
    static func sectionHeader(_ title: String) -> NSView {
        let label = ThemedLabel(labelWithString: title)
        label.font = Typography.header
        label.ink = .secondary
        return label
    }

    /// One settings row: the label at the leading edge, the control at the trailing edge.
    static func row(_ title: String, _ control: NSView) -> NSView {
        let label = ThemedLabel(labelWithString: title)
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSPopUpButton {
            control.widthAnchor.constraint(equalToConstant: pickerWidth).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        return row
    }

    static func footnote(_ text: String) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = Typography.caption
        label.ink = .tertiary
        return label
    }

    /// Adds a row to the Appearance section (the Chief's bubble style, its pet):
    /// a title at the leading edge and `control` at the trailing edge.
    public func addAppearanceRow(_ title: String, control: NSView) {
        let row = Self.row(title, control)
        row.translatesAutoresizingMaskIntoConstraints = false
        appearanceRows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: appearanceRows.widthAnchor).isActive = true
        appearanceHeader.isHidden = false
        appearanceRows.isHidden = false
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

    func buildDiagnostics() {
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = Metrics.space2
        diagnostics.isHidden = true
        for label in [stats, replies, brain] {
            label.font = Typography.caption
            label.ink = .secondary
            label.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
            label.translatesAutoresizingMaskIntoConstraints = false
            diagnostics.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: diagnostics.widthAnchor).isActive = true
        }
        failure.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        brain.stringValue = String(format: HomeEngineStrings.brainFormat, muxHome.path)
        // Show Traces and Show Memory (the built-in Memory Inspector, every build): plain links.
        let traces = HomeChiefLinkButton(title: HomeEngineStrings.openTraces, target: self, action: #selector(openTraces))
        links.addArrangedSubview(traces)
        links.addArrangedSubview(HomeChiefLinkButton(title: HomeEngineStrings.showMemory, target: self, action: #selector(showMemory)))
        links.orientation = .horizontal
        links.spacing = Metrics.space4
        diagnostics.addArrangedSubview(links)
        localViews = [brain, links]
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
