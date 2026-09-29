import AppKit
import CmuxNextDesign

final class DemoContentView: NSView {
    private let top = TabStripDemo.makeModel()
    private let bottom = TabStripDemo.makeModel(style: .compact)
    private let provider = MockTabPreviewProvider()
    private let saved = SavedGroupsBarModel(groups: [
        SavedTabGroupItem(id: "saved-docs", name: "docs", colorToken: .yellow, tabCount: 3),
        SavedTabGroupItem(id: "saved-infra", name: "infra", colorToken: .cyan, tabCount: 5),
        SavedTabGroupItem(id: "saved-dot", name: "", colorToken: .red, tabCount: 2),
    ])
    private let log = NSTextField(labelWithString: "")
    private var strips: [TabStripView] = []
    private var session: DemoDragSession?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.windowBackground.cgColor
        wire(top, other: bottom)
        wire(bottom, other: top)

        let savedBar = SavedGroupsBarView(model: saved)
        saved.intentHandler = { [weak self] intent in
            guard let self, case .open(let id) = intent, let item = self.saved.groups.first(where: { $0.id == id }) else { return }
            self.log.stringValue = Strings.demoLog(String(describing: intent))
            self.reopen(item)
        }
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
        let groupButtons = NSStackView(views: [
            button(Strings.demoGroupSelected) { [top] in
                guard let id = top.selectedID else { return }
                top.send(.createGroup(TabStripDemo.makeGroup(), tabs: [id]))
            },
            button(Strings.demoUngroupSelected) { [top] in
                guard let id = top.selectedID else { return }
                top.send(.removeFromGroup(id, index: nil))
            },
            button(Strings.demoCollapseGroup) { [top] in
                guard let group = top.groups.first?.id else { return }
                top.send(.toggleGroupCollapsed(group))
            },
        ])
        groupButtons.spacing = 8
        buttons.spacing = 8
        log.textColor = Palette.textSecondary
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        for view in [savedBar, topStrip, bottomStrip, buttons, groupButtons, log] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            savedBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            savedBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            savedBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            savedBar.heightAnchor.constraint(equalToConstant: SavedGroupsBarView.preferredHeight),
            topStrip.topAnchor.constraint(equalTo: savedBar.bottomAnchor, constant: 6),
            topStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topStrip.heightAnchor.constraint(equalToConstant: TabStripView.preferredHeight),
            bottomStrip.topAnchor.constraint(equalTo: topStrip.bottomAnchor, constant: 180),
            bottomStrip.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            bottomStrip.trailingAnchor.constraint(equalTo: topStrip.trailingAnchor),
            bottomStrip.heightAnchor.constraint(equalToConstant: TabStripView.preferredHeight),
            buttons.topAnchor.constraint(equalTo: bottomStrip.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            groupButtons.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            groupButtons.leadingAnchor.constraint(equalTo: topStrip.leadingAnchor),
            log.topAnchor.constraint(equalTo: groupButtons.bottomAnchor, constant: 10),
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
            switch intent {
            case .dragBegan(let start):
                self.session = DemoDragSession(source: .tab(start), strips: self.strips) { [weak self] in self?.session = nil }
                return
            case .groupDragBegan(let start):
                self.session = DemoDragSession(source: .group(start), strips: self.strips) { [weak self] in self?.session = nil }
                return
            case .group(.save(let id)):
                if let group = model.group(id), !self.saved.groups.contains(where: { $0.id == id }) {
                    let count = model.members(of: id).count
                    self.saved.groups.append(SavedTabGroupItem(id: id, name: group.name, colorToken: group.colorToken, tabCount: count, isOpen: true))
                }
            case .group(.unsave(let id)):
                self.saved.groups.removeAll { $0.id == id }
            default:
                break
            }
            model.apply(intent) { TabStripDemo.makeTab() }
        }
    }

    /// Restores a saved group into the top strip with fresh tabs.
    private func reopen(_ item: SavedTabGroupItem) {
        guard top.group(item.id) == nil else { return }
        let tabs = (0..<item.tabCount).map { _ in TabStripDemo.makeTab() }
        top.tabs += tabs
        top.send(.createGroup(TabGroupItem(id: item.id, name: item.name, colorToken: item.colorToken, isSaved: true), tabs: tabs.map(\.id)))
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
