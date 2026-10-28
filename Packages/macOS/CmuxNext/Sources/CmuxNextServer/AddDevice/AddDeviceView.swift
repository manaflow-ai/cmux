public import AppKit
import CmuxNextDesign
import Observation

/// The Add Device card's content (AppKit, plans/cmux-next/no-swiftui-DESIGN.md): the title, the
/// three ways, the chosen way's body and the footer. It draws the model again whenever a value it
/// read changes (Observation), and every control runs ``AddDeviceModel/perform(_:)``.
@MainActor
public final class AddDeviceView: NSView {
    public let model: AddDeviceModel
    /// The card should close (a hand-off to Add Machine or Add Server, Done or Cancel).
    public var onClose: () -> Void = {}
    /// The fitting size changed (another way, the list loaded).
    public var onResize: (NSSize) -> Void = { _ in }

    static let width: CGFloat = 440
    static let listMaxHeight: CGFloat = 228

    private let stack = NSStackView()
    private var actions: [AddDeviceAction] = []

    public init(model: AddDeviceModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("cmux.addDevice")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space4
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: Metrics.space6, bottom: Metrics.space5, right: Metrics.space6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the model and re-draws when a value read here changes.
    private func render() {
        withObservationTracking { build() } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        layoutSubtreeIfNeeded()
        onResize(fittingSize)
    }

    private func build() {
        actions.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = Self.width - 2 * Metrics.space6
        stack.addArrangedSubview(label(AddDeviceStrings.title, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis),
                                       color: Palette.textPrimary, width: width, header: true))
        stack.addArrangedSubview(label(AddDeviceStrings.subtitle, font: Typography.body, color: Palette.textSecondary, width: width))
        let ways = segmented(AddDeviceWay.allCases.map(AddDeviceStrings.way), selected: AddDeviceWay.allCases.firstIndex(of: model.way) ?? 0,
                             action: #selector(wayChanged(_:)), id: "cmux.addDevice.way")
        stack.addArrangedSubview(ways)
        ways.widthAnchor.constraint(equalToConstant: width).isActive = true
        switch model.way {
        case .network: buildNetwork(width)
        case .code: stack.addArrangedSubview(label(AddDeviceStrings.codeHelp, font: Typography.body, color: Palette.textPrimary, width: width))
        case .newDevice: buildNewDevice(width)
        }
        stack.addArrangedSubview(label(AddDeviceStrings.approvalNote, font: Typography.caption, color: Palette.textTertiary, width: width))
        stack.addArrangedSubview(footer(width))
    }

    private func buildNetwork(_ width: CGFloat) {
        stack.addArrangedSubview(label(AddDeviceStrings.networkHelp, font: Typography.body, color: Palette.textSecondary, width: width))
        switch model.candidates {
        case .loading:
            let row = NSStackView()
            row.spacing = Metrics.space2
            row.addArrangedSubview(StatusIndicatorView.spinner())
            row.addArrangedSubview(label(AddDeviceStrings.networkLoading, font: Typography.body, color: Palette.textSecondary, width: width - 24))
            stack.addArrangedSubview(row)
        case .unavailable:
            stack.addArrangedSubview(label(AddDeviceStrings.networkUnavailable, font: Typography.body, color: Palette.textPrimary, width: width))
        case .loaded:
            if let problem = model.networkProblem {
                stack.addArrangedSubview(label(problem, font: Typography.body, color: Palette.danger, width: width))
                // The ssh config's computers do not need the network.
                if !model.available.isEmpty { stack.addArrangedSubview(list(model.available, width: width)) }
            } else if model.available.isEmpty {
                stack.addArrangedSubview(label(AddDeviceStrings.networkEmpty, font: Typography.body, color: Palette.textPrimary, width: width))
            } else {
                stack.addArrangedSubview(list(model.available, width: width))
            }
        }
    }

    private func list(_ computers: [DeviceListing.Available], width: CGFloat) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Metrics.space1
        rows.translatesAutoresizingMaskIntoConstraints = false
        for computer in computers {
            rows.addArrangedSubview(row(computer, width: width - Metrics.space2))
        }
        let rowHeight: CGFloat = 34
        let height = min(CGFloat(computers.count) * (rowHeight + Metrics.space1), Self.listMaxHeight)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = computers.count * Int(rowHeight + Metrics.space1) > Int(Self.listMaxHeight)
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])
        scroll.setAccessibilityIdentifier("cmux.addDevice.network.list")
        return scroll
    }

    private func row(_ computer: DeviceListing.Available, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.space3
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let name = label(computer.name, font: Typography.bodyEmphasized, color: Palette.textPrimary, width: nil)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        let detail = (computer.fromSSHConfig ? [AddDeviceStrings.sshConfig]
            : [computer.os, computer.mine ? AddDeviceStrings.yours : nil].compactMap { $0 }).filter { !$0.isEmpty }
        row.addArrangedSubview(label(detail.joined(separator: " · "), font: Typography.caption, color: Palette.textSecondary, width: nil))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(button(.pick(computer), key: nil, id: "cmux.addDevice.add.\(computer.name)"))
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(computer.name), \(detail.joined(separator: ", "))")
        return row
    }

    private func buildNewDevice(_ width: CGFloat) {
        let platforms = segmented(AddDevicePlatform.allCases.map(AddDeviceStrings.platform),
                                  selected: AddDevicePlatform.allCases.firstIndex(of: model.platform) ?? 0,
                                  action: #selector(platformChanged(_:)), id: "cmux.addDevice.platform")
        stack.addArrangedSubview(platforms)
        guard let line = model.platform.setupLine else {
            stack.addArrangedSubview(label(AddDeviceStrings.phoneHelp, font: Typography.body, color: Palette.textPrimary, width: width))
            return
        }
        stack.addArrangedSubview(label(AddDeviceStrings.newDeviceHelp, font: Typography.body, color: Palette.textSecondary, width: width))
        let field = NSTextField(wrappingLabelWithString: line)
        field.isSelectable = true
        field.focusRingType = .none
        field.font = Typography.system(.monospaced, size: TypeScale.detail)
        field.textColor = Palette.textPrimary
        field.preferredMaxLayoutWidth = width - 2 * Metrics.space3
        field.setAccessibilityIdentifier("cmux.addDevice.setupLine")
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Metrics.space3),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Metrics.space3),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: Metrics.space3),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Metrics.space3),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        stack.addArrangedSubview(box)
    }

    private func footer(_ width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.space2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        for item in model.buttons {
            row.addArrangedSubview(button(item.action, key: item.key, id: "cmux.addDevice.button.\(Self.name(item.action))"))
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    static func name(_ action: AddDeviceAction) -> String {
        switch action {
        case .pick: "add"
        case .otherComputer: "otherComputer"
        case .newCloudMachine: "newCloudMachine"
        case .enterCode: "enterCode"
        case .copyLine: "copyLine"
        case .done: "done"
        case .cancel: "cancel"
        }
    }

    private func button(_ action: AddDeviceAction, key: AddDeviceButton.Key?, id: String) -> NSView {
        let role: CmuxDialogButton.Role = switch key {
        case .return: .default
        case .escape: .cancel
        case nil: .normal
        }
        let spec = CmuxDialogButton(id: Self.name(action), title: AddDeviceStrings.button(action, copied: model.copied), role: role)
        let view = CmuxDialogButtonView(standalone: spec, target: self, action: #selector(pressed(_:)))
        view.tag = actions.count
        actions.append(action)
        view.setAccessibilityIdentifier(id)
        return view
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        if model.perform(actions[sender.tag]) { onClose() }
    }

    @objc private func wayChanged(_ sender: NSSegmentedControl) {
        guard AddDeviceWay.allCases.indices.contains(sender.selectedSegment) else { return }
        model.choose(AddDeviceWay.allCases[sender.selectedSegment])
    }

    @objc private func platformChanged(_ sender: NSSegmentedControl) {
        guard AddDevicePlatform.allCases.indices.contains(sender.selectedSegment) else { return }
        model.choose(AddDevicePlatform.allCases[sender.selectedSegment])
    }

    private func segmented(_ titles: [String], selected: Int, action: Selector, id: String) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: self, action: action)
        control.selectedSegment = selected
        control.segmentDistribution = .fillEqually
        control.font = Typography.body
        control.setAccessibilityIdentifier(id)
        return control
    }

    private func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat?, header: Bool = false) -> NSTextField {
        let field = width == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        if let width { field.preferredMaxLayoutWidth = width }
        if header { field.setAccessibilityRole(.staticText); field.setAccessibilityLabel(text) }
        return field
    }
}

/// A top-down document view for the computer list's scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
