import AppKit
import CmuxNextDesign
import CmuxNextHome

/// The profile's column: the header (avatar, name, tabs), the expanded page's Details, the Computer
/// pane and, in the popover, the settings card; in a scroll view (the page's under its ✕).
extension HomeChiefProfileView {
    func buildColumn() {
        avatar.isEnabled = settings != nil  // the popover's avatar is the card's: a click changes the picture
        nameLabel.font = Typography.system(size: TypeScale.title, weight: TypeScale.regular)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        placeLabel.font = Typography.body
        placeLabel.ink = .secondary
        placeLabel.alignment = .center
        let allSettings = HomeChiefSettingsView.footerButton(HomeEngineStrings.allChiefSettings, target: self, action: #selector(openSettings))
        details.orientation = .vertical
        details.alignment = .centerX
        details.spacing = Metrics.space2
        details.addArrangedSubview(placeLabel)
        details.addArrangedSubview(allSettings)
        buildGateBox()
        computerPane.orientation = .vertical
        computerPane.alignment = .centerX
        // The screen, its caption, then the control bar the screen's width (the popover and the page alike).
        computerPane.spacing = Metrics.space4
        for view in [computer, gateBox, controlBar] as [NSView] { computerPane.addArrangedSubview(view) }
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        for view in [avatar, nameLabel, tabs, details, computerPane] as [NSView] { column.addArrangedSubview(view) }
        column.setCustomSpacing(Self.nameGap, after: avatar)
        column.setCustomSpacing(Self.tabsGap, after: nameLabel)
        column.setCustomSpacing(Self.tabsGap, after: tabs)
        column.translatesAutoresizingMaskIntoConstraints = false
        if let settings {
            column.setCustomSpacing(HomeChiefSettingsView.sectionGap, after: computerPane)
            column.addArrangedSubview(settings)
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(closeButton)
        // The popover closes on a click outside or Escape, as every popover does: only the page has a ✕.
        closeButton.isHidden = settings != nil
        // The card's rows keep its own inset; the computer lines up with them.
        let inset: CGFloat = settings == nil ? 0 : HomeChiefSettingsView.inset
        for view in [nameLabel, details, computerPane] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: view === computerPane ? -2 * inset : 0).isActive = true
        }
        for view in [computer, gateBox, controlBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: computerPane.widthAnchor).isActive = true
        }
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: topInset),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            document.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: Self.bottomInset),
            closeButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.closeCenterY),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.closeInset),
        ])
        // The screen's 16:10; in the popover the note's card stops at a sensible height, on the page it
        // takes the screen's place whole.
        if settings != nil { gateBox.heightAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true }
        let ratio = gateBox.heightAnchor.constraint(equalTo: gateBox.widthAnchor, multiplier: 10.0 / 16.0)
        ratio.priority = .defaultHigh
        ratio.isActive = true
        // A frame narrower than the card clips its edges (it stays centered) rather than break its rows.
        let fits = column.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: settings == nil ? -32 : 0)
        fits.priority = settings == nil ? .required : .defaultHigh
        fits.isActive = true
        if settings == nil {
            // The page uses the whole pane: as wide as it is, and only as wide as lets the 16:10 screen
            // (or its note) and the bar under it fit the pane's height below the header.
            // Its constant follows the page's height (layout()): the scroll view's clip is not under Auto Layout,
            // so no anchor of it carries the height.
            let fitsHeight = column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.expandedWidth(height: bounds.height))
            fitsHeight.priority = .defaultHigh
            heightFit = fitsHeight
            let wide = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -32)
            wide.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)
            NSLayoutConstraint.activate([fitsHeight, wide])
        } else {
            column.widthAnchor.constraint(equalToConstant: HomeChiefSettingsView.width).isActive = true
        }
    }

    private func buildGateBox() {
        gateBox.wantsLayer = true
        gateBox.layer?.cornerRadius = HomeChiefComputerSection.screenCorner
        gateBox.layer?.cornerCurve = .continuous
        gateLabel.font = Typography.system(size: TypeScale.field, weight: TypeScale.regular)
        gateLabel.alignment = .center
        gateButton.bezelStyle = .rounded
        gateButton.target = self
        gateButton.action = #selector(gateAction)
        gateButton.setAccessibilityIdentifier("cmux.home.chief.computer.gate")
        gateMoveButton.bezelStyle = .rounded
        gateMoveButton.target = self
        gateMoveButton.action = #selector(moveToCloud)
        gateMoveButton.setAccessibilityIdentifier("cmux.home.chief.computer.gate.move")
        let buttons = NSStackView(views: [gateButton, gateMoveButton])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space2
        let note = NSStackView(views: [gateLabel, buttons])
        note.orientation = .vertical
        note.alignment = .centerX
        note.spacing = Metrics.space3
        note.translatesAutoresizingMaskIntoConstraints = false
        gateBox.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: gateBox.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: gateBox.centerYAnchor),
            note.widthAnchor.constraint(equalTo: gateBox.widthAnchor, constant: -32),
        ])
        gateLabel.preferredMaxLayoutWidth = (settings == nil ? Self.expandedNoteWidth : Self.columnWidth) - 32
    }

    func applyGateFill() {
        performWithTheme { gateBox.layer?.backgroundColor = Palette.hoverFill.cgColor }
    }

    @objc private func gateAction() {
        switch shownGate {
        case .paywall: onUpgrade()
        case .notSetUp, .noComputer: provision()
        default: onMoveToCloud()
        }
    }

    @objc private func moveToCloud() { onMoveToCloud() }
}

/// The scroll view's document: rows from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
