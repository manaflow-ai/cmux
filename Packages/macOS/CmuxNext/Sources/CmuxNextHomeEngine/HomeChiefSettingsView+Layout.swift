public import AppKit
import CmuxNextActions
import CmuxNextDesign
import Foundation

/// The settings card's sections and rows (`HomeChiefSettingsView`).
extension HomeChiefSettingsView {
    // MARK: Layout

    /// Adds `view` across the card, to the tab section being built (``filling``), else to the card.
    func addFullWidth(_ view: NSView) {
        let target = filling.map { sections[$0] } ?? stack
        view.translatesAutoresizingMaskIntoConstraints = false
        target.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true
    }

    /// The avatar (a menu changes it) beside the Name row, where the brain runs under the name. The
    /// profile panel shows the avatar in its header, which leaves the Name row.
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
        let name = Self.row(HomeEngineStrings.name, text, fills: true)
        let row = NSStackView(views: [avatarButton, name])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space3
        // The name takes the rest of the row.
        name.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        return row
    }

    /// A section's title: secondary ink, the header weight.
    static func sectionHeader(_ title: String) -> NSView {
        let label = ThemedLabel(labelWithString: title)
        label.font = Typography.header
        label.ink = .secondary
        return label
    }

    /// The label column's width: the card's rows less the picker column and the gap between them.
    static let labelWidth: CGFloat = width - 2 * inset - pickerWidth - labelGap
    static let labelGap: CGFloat = 8

    /// One settings row of the card's two columns: the label in the label column (it wraps rather
    /// than truncates), the control at the start of the control column. A picker or a field (`fills`)
    /// takes the whole control column. The label's first line sits on the control's first line, so a
    /// control taller than a line (the pet grid, the name with the line under it) keeps its label at its top.
    static func row(_ title: String, _ control: NSView, fills: Bool? = nil) -> NSView {
        let label = ThemedLabel(wrappingLabelWithString: title)
        label.font = Typography.body
        label.preferredMaxLayoutWidth = labelWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        let line = min(control.fittingSize.height, Metrics.controlHeight)
        let labelLine = NSLayoutManager().defaultLineHeight(for: Typography.body)
        NSLayoutConstraint.activate([
            cell.widthAnchor.constraint(equalToConstant: labelWidth),
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: max(0, ((line - labelLine) / 2).rounded())),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [cell, control])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = labelGap
        if fills ?? (control is NSPopUpButton || control is ThemedFieldBox) {
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        } else {
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            row.addArrangedSubview(spacer)
        }
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

    /// The closed disclosure over the diagnostics: its title, then the triangle, one click target.
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
        // The title is the section's header at the column's edge; the triangle follows it.
        let row = NSStackView(views: [title, diagnosticsToggle])
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
