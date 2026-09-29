import AppKit
import CmuxNextDesign

final class DemoContentView: NSView {
    private let top = TabStripDemo.makeModel()
    private let bottom = TabStripDemo.makeModel(style: .compact)
    private let provider = MockTabPreviewProvider()
    private let log = NSTextField(labelWithString: "")
    private var strips: [TabStripView] = []
    private var session: DemoDragSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.windowBackground.cgColor
        wire(top, other: bottom)
        wire(bottom, other: top)

        let topStrip = TabStripView(model: top, background: .glass)
        let bottomStrip = TabStripView(model: bottom, background: .glass)
        topStrip.dragsWindowFromEmptySpace = false
        bottomStrip.dragsWindowFromEmptySpace = false
        for strip in [topStrip, bottomStrip] { strip.previewProvider = provider }
        strips = [topStrip, bottomStrip]

        let buttons = NSStackView(views: [
            button(Strings.demoAddTab) { [top] in top.send(.newTab(after: top.selectedID)) },
            button(Strings.demoAddMany) { [top] in for _ in 0..<10 { top.send(.newTab(after: nil)) } },
            button(Strings.demoToggleBusy) { [top] in top.mutateSelected { $0.isBusy.toggle() } },
            button(Strings.demoToggleUnread) { [top] in top.mutateSelected { $0.isUnread.toggle() } },
            button(Strings.demoCycleStatus) { [top] in
                top.mutateSelected {
                    switch $0.status {
                    case .none: $0.status = .needsInput
                    case .needsInput: $0.status = .success
                    case .success: $0.status = .failure
                    case .failure: $0.status = .none
                    }
                }
            },
            button(Strings.demoCompact) { [top] in top.style = top.style == .chrome ? .compact : .chrome },
        ])
        buttons.spacing = 8
        log.textColor = Palette.textSecondary
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        for view in [topStrip, bottomStrip, buttons, log] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            topStrip.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            topStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topStrip.heightAnchor.constraint(equalToConstant: TabStripView.preferredHeight),
            bottomStrip.topAnchor.constraint(equalTo: topStrip.bottomAnchor, constant: 180),
            bottomStrip.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            bottomStrip.trailingAnchor.constraint(equalTo: topStrip.trailingAnchor),
            bottomStrip.heightAnchor.constraint(equalToConstant: TabStripView.preferredHeight),
            buttons.topAnchor.constraint(equalTo: bottomStrip.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            log.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            log.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            log.trailingAnchor.constraint(equalTo: topStrip.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func wire(_ model: TabStripModel, other: TabStripModel) {
        model.intentHandler = { [weak self, weak model] intent in
            guard let self, let model else { return }
            self.log.stringValue = Strings.demoLog(String(describing: intent))
            if case .dragBegan(let start) = intent {
                self.session = DemoDragSession(start: start, strips: self.strips) { [weak self] in self?.session = nil }
                return
            }
            model.apply(intent) { TabStripDemo.makeTab() }
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .push
        return button
    }
}

private extension TabStripModel {
    func mutateSelected(_ change: (inout TabItem) -> Void) {
        guard let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&tabs[index])
    }
}

private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() {
        handler?()
    }
}
