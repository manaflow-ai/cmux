import AppKit
import CmuxNextDesign

/// The profile's column: the header (avatar, name, tabs), the expanded page's Details, the Computer
/// pane and, in the panel, the settings card; in a scroll view under the ✕.
extension HomeChiefProfileView {
    func buildColumn() {
        avatar.isEnabled = settings != nil  // the panel's avatar is the card's: a click changes the picture
        nameLabel.font = Typography.system(size: TypeScale.title, weight: TypeScale.regular)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        placeLabel.font = Typography.body
        placeLabel.ink = .secondary
        placeLabel.alignment = .center
        let allSettings = HomeChiefLinkButton(title: HomeEngineStrings.allChiefSettings, target: self, action: #selector(openSettings))
        details.orientation = .vertical
        details.alignment = .centerX
        details.spacing = Metrics.space2
        details.addArrangedSubview(placeLabel)
        details.addArrangedSubview(allSettings)
        buildGateBox()
        computerPane.orientation = .vertical
        computerPane.alignment = .centerX
        computerPane.spacing = Metrics.space3
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
            column.setCustomSpacing(Metrics.space3, after: computerPane)
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
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.avatarTop),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            document.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // The screen's 16:10 in the panel; on the wide page the note's card stops at a sensible height.
            gateBox.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        let ratio = gateBox.heightAnchor.constraint(equalTo: gateBox.widthAnchor, multiplier: 10.0 / 16.0)
        ratio.priority = .defaultHigh
        ratio.isActive = true
        // A pane narrower than the panel clips the card's trailing edge rather than break its rows.
        let fits = column.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: settings == nil ? -32 : 0)
        fits.priority = settings == nil ? .required : .defaultHigh
        fits.isActive = true
        if settings == nil {
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.expandedWidth).isActive = true
            let wide = column.widthAnchor.constraint(equalToConstant: Self.expandedWidth)
            wide.priority = .defaultHigh
            wide.isActive = true
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
        let note = NSStackView(views: [gateLabel, gateButton])
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
        gateLabel.preferredMaxLayoutWidth = (settings == nil ? Self.expandedWidth : Self.columnWidth) - 32
    }

    func applyGateFill() {
        performWithTheme { gateBox.layer?.backgroundColor = Palette.hoverFill.cgColor }
    }

    @objc private func gateAction() {
        if shownGate == .paywall { onUpgrade() } else { onMoveToCloud() }
    }
}

/// The scroll view's document: rows from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
