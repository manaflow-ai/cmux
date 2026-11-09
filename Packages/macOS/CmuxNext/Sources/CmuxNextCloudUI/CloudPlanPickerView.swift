public import AppKit
public import CmuxNextDesign

/// The plan picker's page (``CloudPlanPicker``), in AppKit: a title, the Monthly/Annual toggle, the Pro, Max and
/// Team cards and the way out (Run on This Mac, Not Now). It fills the window and draws in the window's theme
/// tokens, light or dark, again on each appearance change. Layout after Cursor's upgrade gate
/// (cmux-design-references `apps/cursor/live/automations-plan-gate.png`: one centered heading over the choices,
/// quiet chrome around them), with the cards the issue specifies. The presenter (``CloudPlanPickerPresenter``)
/// sets ``answer``; the page calls it once.
@MainActor
public final class CloudPlanPickerHostingView: NSView {
    /// The person's pick (the presenter's), once.
    var answer: (@MainActor (CloudPlanPicker.Choice?) -> Void)?
    private var picker: CloudPlanPicker
    private let scroll = NSScrollView()
    private let page = CloudPlanPickerFlippedView()
    private let stack = NSStackView()
    private let titleLabel = ChromeLabel(wrappingLabelWithString: CloudPlanPickerStrings.title)
    private let subtitleLabel: ChromeLabel
    private let intervalControl = ThemedSegmentedControl()
    private let savingLabel = ChromeLabel(labelWithString: CloudPlanPickerStrings.save(CloudPlanPicker.bestAnnualSaving))
    private let cardsRow = NSStackView()
    private var cards: [CloudPlanCardView] = []
    let notNowButton: CmuxDialogButtonView
    let runHereButton: CmuxDialogButtonView?

    init(picker: CloudPlanPicker) {
        self.picker = picker
        subtitleLabel = ChromeLabel(wrappingLabelWithString: picker.recommended == .max ? CloudPlanPickerStrings.subtitleMax : CloudPlanPickerStrings.subtitle)
        notNowButton = CmuxDialogButtonView(standalone: CmuxDialogButton(id: "cloud-plan-not-now", title: CloudMachineCapCard.Strings.notNow, role: .cancel),
                                            target: nil, action: #selector(CloudPlanPickerHostingView.notNowPressed))
        runHereButton = picker.offersRunHere
            ? CmuxDialogButtonView(standalone: CmuxDialogButton(id: "cloud-plan-run-here", title: CloudMachineCapCard.Strings.runHere),
                                   target: nil, action: #selector(CloudPlanPickerHostingView.runHerePressed))
            : nil
        super.init(frame: .zero)
        notNowButton.target = self
        runHereButton?.target = self
        identifier = NSUserInterfaceItemIdentifier("cmux.cloud.planPicker")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(CloudPlanPickerStrings.title)
        setAccessibilityModal(true)
        wantsLayer = true
        build()
        renderCards()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The picker still waits for the person's pick.
    public var isWaiting: Bool { answer != nil }

    /// Picks `choice` as a click on its button does (a plan's Get button, Run on This Mac).
    public func choose(_ choice: CloudPlanPicker.Choice) { take()?(choice) }

    /// Not Now: no plan, nothing created.
    public func notNow() { take()?(nil) }

    /// Shows `interval`'s prices, as a click on the toggle does.
    public func show(_ interval: CloudPlanPicker.Interval) {
        intervalControl.selectedSegment = interval == .month ? 0 : 1
        guard picker.interval != interval else { return }
        picker.interval = interval
        renderCards()
        applyColors()
    }

    /// What each shown card says, top to bottom (tests read it).
    public var shownCards: [[String]] { cards.map(\.shownText) }

    /// The answer, cleared: the person's first pick is the only one.
    private func take() -> (@MainActor (CloudPlanPicker.Choice?) -> Void)? {
        defer { answer = nil }
        return answer
    }

    public override func cancelOperation(_ sender: Any?) { notNow() }

    @objc private func notNowPressed() { notNow() }
    @objc private func runHerePressed() { choose(.runHere) }
    @objc private func intervalPicked() { show(intervalControl.selectedSegment == 1 ? .year : .month) }

    // MARK: Layout

    private func build() {
        let padding = Metrics.space6
        titleLabel.font = Typography.title
        titleLabel.alignment = .center
        subtitleLabel.font = Typography.body
        subtitleLabel.alignment = .center
        titleLabel.setAccessibilityRole(.staticText)
        savingLabel.font = Typography.caption

        intervalControl.segmentCount = 2
        intervalControl.setLabel(CloudPlanPickerStrings.monthly, forSegment: 0)
        intervalControl.setLabel(CloudPlanPickerStrings.annual, forSegment: 1)
        intervalControl.trackingMode = .selectOne
        intervalControl.font = Typography.body
        intervalControl.selectedSegment = picker.interval == .month ? 0 : 1
        intervalControl.target = self
        intervalControl.action = #selector(intervalPicked)
        intervalControl.identifier = NSUserInterfaceItemIdentifier("cmux.cloud.planPicker.interval")
        let toggle = NSStackView(views: [intervalControl, savingLabel])
        toggle.orientation = .horizontal
        toggle.spacing = Metrics.space2
        toggle.alignment = .centerY

        cardsRow.orientation = .horizontal
        cardsRow.alignment = .top
        cardsRow.distribution = .fillEqually
        cardsRow.spacing = Metrics.space4
        cardsRow.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [runHereButton, notNowButton].compactMap { $0 })
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space3

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space5
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSStackView(views: [titleLabel, subtitleLabel])
        heading.orientation = .vertical
        heading.alignment = .centerX
        heading.spacing = Metrics.space2
        [heading, toggle, cardsRow, buttons].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(Metrics.space4, after: heading)

        page.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        SystemScrollers.follow(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let maxWidth: CGFloat = (picker.shownPlans.count == 1 ? 360 : 960) * Typography.userScale
        let clip = scroll.contentView
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: maxWidth)
        preferredWidth.priority = .defaultHigh
        let fillHeight = page.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor)
        // As tall as the window unless the content needs more (then it scrolls).
        let windowHeight = page.heightAnchor.constraint(equalTo: clip.heightAnchor).withPriority(.defaultLow)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.leadingAnchor.constraint(equalTo: clip.leadingAnchor), page.topAnchor.constraint(equalTo: clip.topAnchor),
            page.widthAnchor.constraint(equalTo: clip.widthAnchor), fillHeight, windowHeight,
            // Centered in the window, at most `maxWidth` wide, padded on every side.
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: page.centerYAnchor).withPriority(.defaultLow),
            stack.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -padding),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            stack.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -2 * padding),
            preferredWidth,
            cardsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560 * Typography.userScale),
        ])
    }

    /// The cards for the picker's interval (the toggle draws them again).
    private func renderCards() {
        cards.forEach { $0.removeFromSuperview() }
        cards = picker.shownPlans.map { plan in
            CloudPlanCardView(plan: plan, picker: picker) { [weak self] choice in self?.choose(choice) }
        }
        cards.forEach(cardsRow.addArrangedSubview)
        // One level row: every card as tall as the tallest.
        for card in cards.dropFirst() { card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true }
    }

    private func applyColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.contentBackground.cgColor
            titleLabel.textColor = Palette.textPrimary
            subtitleLabel.textColor = Palette.textSecondary
            savingLabel.textColor = Palette.success
            cards.forEach { $0.applyColors() }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }
}

/// One plan: name, price, billing, included usage, its Get button, what is due today and its machine limits.
@MainActor
final class CloudPlanCardView: NSView {
    private let isRecommended: Bool
    private let nameLabel: ChromeLabel
    private let recommendedLabel = ChromeLabel(labelWithString: CloudPlanPickerStrings.recommended)
    private let priceLabel: ChromeLabel
    private let unitLabel: ChromeLabel
    private let billingLabel: ChromeLabel
    private let includedLabel: ChromeLabel
    private let todayLabel: ChromeLabel
    private let featureLabels: [ChromeLabel]
    private let divider = NSView()
    let getButton: CmuxDialogButtonView
    private let choice: CloudPlanPicker.Choice
    private let pick: @MainActor (CloudPlanPicker.Choice) -> Void

    init(plan: CloudPlanPicker.Plan, picker: CloudPlanPicker, pick: @escaping @MainActor (CloudPlanPicker.Choice) -> Void) {
        isRecommended = picker.recommended == plan.id
        choice = picker.choice(plan)
        self.pick = pick
        nameLabel = ChromeLabel(labelWithString: CloudPlanPickerStrings.name(plan.id))
        priceLabel = ChromeLabel(labelWithString: CloudPlanPicker.price(picker.monthlyPrice(plan)))
        unitLabel = ChromeLabel(labelWithString: plan.perSeat ? CloudPlanPickerStrings.perSeatMonth : CloudPlanPickerStrings.perMonth)
        let billing = picker.billing(plan) == .year ? plan.yearly.map { CloudPlanPickerStrings.billedYearly(CloudPlanPicker.price($0)) } : nil
        billingLabel = ChromeLabel(wrappingLabelWithString: billing ?? CloudPlanPickerStrings.billedMonthly)
        includedLabel = ChromeLabel(wrappingLabelWithString: CloudPlanPickerStrings.included(CloudPlanPicker.price(plan.includedUsage), perSeat: plan.perSeat))
        todayLabel = ChromeLabel(wrappingLabelWithString: CloudPlanPickerStrings.today(CloudPlanPicker.price(picker.dueToday(plan))))
        featureLabels = [
            CloudPlanPickerStrings.machineSize(cpu: plan.machineCPU, memoryGB: plan.machineMemoryGB),
            CloudPlanPickerStrings.pool(cpu: plan.poolCPU, memoryGB: plan.poolMemoryGB, perSeat: plan.perSeat),
            CloudPlanPickerStrings.machines(plan.machines, perSeat: plan.perSeat),
            CloudPlanPickerStrings.storage(plan.storageGB),
        ].map(ChromeLabel.init(wrappingLabelWithString:))
        // The recommended plan's button is the default: it answers Return and shows the key.
        getButton = CmuxDialogButtonView(standalone: CmuxDialogButton(id: "cloud-plan-\(plan.id.rawValue)", title: CloudPlanPickerStrings.choose(plan.id),
                                                                      role: picker.recommended == plan.id ? .default : .normal),
                                         target: nil, action: #selector(CloudPlanCardView.getPressed))
        super.init(frame: .zero)
        getButton.target = self
        wantsLayer = true
        layer?.cornerRadius = Metrics.insetCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(CloudPlanPickerStrings.name(plan.id))
        identifier = NSUserInterfaceItemIdentifier("cmux.cloud.planPicker.\(plan.id.rawValue)")
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func getPressed() { pick(choice) }

    /// What the card says, top to bottom.
    var shownText: [String] {
        ([nameLabel] + (isRecommended ? [recommendedLabel] : []) + [priceLabel, unitLabel, billingLabel, includedLabel]).map(\.stringValue)
            + [getButton.button.title, todayLabel.stringValue] + featureLabels.map(\.stringValue)
    }

    private func build() {
        nameLabel.font = Typography.header
        recommendedLabel.font = Typography.caption
        recommendedLabel.isHidden = !isRecommended
        priceLabel.font = Typography.title
        unitLabel.font = Typography.body
        for label in [billingLabel, todayLabel] { label.font = Typography.caption }
        includedLabel.font = Typography.body
        featureLabels.forEach { $0.font = Typography.body }

        let header = NSStackView(views: [nameLabel, NSView(), recommendedLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        let price = NSStackView(views: [priceLabel, unitLabel])
        price.orientation = .horizontal
        price.alignment = .firstBaseline
        price.spacing = Metrics.space1
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let features = NSStackView(views: featureLabels)
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = Metrics.space2

        let stack = NSStackView(views: [header, price, billingLabel, includedLabel, getButton, todayLabel, divider, features])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.setCustomSpacing(Metrics.space1, after: price)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset = Metrics.space4
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset),
            // No taller than its content unless the row makes it (the cards share one height).
            heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 2 * inset).withPriority(.defaultLow),
        ])
        for view in [header, billingLabel, includedLabel, getButton, todayLabel, divider, features] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        featureLabels.forEach { $0.widthAnchor.constraint(equalTo: features.widthAnchor).isActive = true }
    }

    /// Colors in the scope's theme (the page calls it inside `performWithTheme`).
    func applyColors() {
        layer?.backgroundColor = Palette.chromeBackground.cgColor
        layer?.borderColor = (isRecommended ? Palette.accent : Palette.separator).cgColor
        divider.layer?.backgroundColor = Palette.separator.cgColor
        for label in [nameLabel, priceLabel, includedLabel] { label.textColor = Palette.textPrimary }
        for label in [unitLabel, billingLabel, todayLabel] + featureLabels { label.textColor = Palette.textSecondary }
        recommendedLabel.textColor = Palette.accent
    }
}

/// The scrolled page: top-down, so a short window shows the title first.
final class CloudPlanPickerFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
