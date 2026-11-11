import AppKit
public import CmuxNextActions
import CmuxNextDesign

/// One Cloud machine the card's Computer picker offers (cmux issue 36047).
public nonisolated struct HomeChiefCloudComputer: Equatable, Sendable {
    /// The Cloud machine id (`cmux cloud list-machines`' `machine_id`).
    public var id: String
    /// The machine's name, as the sidebar shows it.
    public var title: String
    /// The name is the one cmux gives a machine nobody named ("Cloud Machine 5").
    public var isGenericName: Bool
    /// Machines tooling made for itself (leases, agent infrastructure), not the person's own.
    public var isInternal: Bool

    public init(id: String, title: String, isGenericName: Bool = false, isInternal: Bool = false) {
        self.id = id
        self.title = title
        self.isGenericName = isGenericName
        self.isInternal = isInternal || title.lowercased().hasPrefix("lease-")
    }

    /// engine.json's `computer` for this machine, the `--target` its Cloud actions take.
    public var target: String { "machine:\(id)" }
}

/// The Computer row (cmux issue 36047): where a Chief of this Mac does computer use. "This Mac"
/// (the default) or one of the account's Cloud machines, which the brain saves in engine.json
/// (`chief.engine.set computer`) and names in each turn, so the Chief drives that machine's desktop
/// instead of this Mac's. A Cloud or paired-server Chief has no row: its computer is its own.
extension HomeChiefSettingsView {
    /// The picker's last item: makes a Cloud machine (the app's own create card, which asks first).
    static let newComputerTag = 1

    func addComputerRow() {
        computerRow.orientation = .vertical
        computerRow.alignment = .leading
        computerRow.spacing = Metrics.space2
        computerRow.setAccessibilityIdentifier("cmux.home.chief.computerRow")
        // The section's title names the picker, so the picker takes the whole line; Show Desktop sits on the title's.
        computerDesktop.setAccessibilityIdentifier("cmux.home.chief.computerDesktop")
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [Self.sectionHeader(HomeEngineStrings.computerSection), spacer, computerDesktop])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        computerRow.addArrangedSubview(header)
        computerPicker.target = self
        computerPicker.action = #selector(pickedComputer(_:))
        computerPicker.font = Typography.body
        computerPicker.setAccessibilityLabel(HomeEngineStrings.computerRow)
        computerPicker.setAccessibilityIdentifier("cmux.home.chief.computer")
        computerPicker.translatesAutoresizingMaskIntoConstraints = false
        // A long machine name truncates in the line; it never widens the card.
        computerPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (computerPicker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        computerRow.addArrangedSubview(computerPicker)
        computerNote.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        computerRow.addArrangedSubview(computerNote)
        addFullWidth(computerRow)
        header.widthAnchor.constraint(equalTo: computerRow.widthAnchor).isActive = true
        computerPicker.widthAnchor.constraint(equalTo: computerRow.widthAnchor).isActive = true
        gap(after: computerRow)
        computerRow.isHidden = !source.isLocal
        showComputer(nil)
    }

    /// Fills the picker for `computer` (engine.json's `machine:<id>`, nil: this Mac), in
    /// ``HomeChiefComputerMenu``'s order. Items are added as menu items, never by title: two machines
    /// may share a name (`addItem(withTitle:)` keeps one).
    func showComputer(_ computer: String?) {
        shownComputer = computer
        let machines = cloudComputers()
        let menu = NSMenu()
        for row in HomeChiefComputerMenu(chief: shownName, computer: computer, machines: machines).rows {
            menu.addItem(Self.menuItem(row))
        }
        computerPicker.menu = menu
        let index = computer.flatMap { target in menu.items.firstIndex { ($0.representedObject as? String) == target } } ?? 0
        computerPicker.selectItem(at: index)
        // A Chief that moved off this Mac keeps the computer it took here: its row stays while one is
        // set, so the owner can still detach it.
        let hidden = !source.isLocal && computer == nil
        if computerRow.isHidden != hidden { computerRow.isHidden = hidden }
        computerNote.stringValue = computer != nil ? HomeEngineStrings.computerCloudNote : HomeEngineStrings.computerMacNote
        // Show Desktop opens a Cloud machine's; the Chief's own computer shows in its profile's Computer tab.
        let machine = attachedMachine != nil
        if computerDesktop.isHidden == machine { computerDesktop.isHidden = !machine }
        onComputerShown()
        nameAttachedComputer(machines.first { $0.target == computer })
    }

    private static func menuItem(_ row: HomeChiefComputerMenu.Row) -> NSMenuItem {
        switch row {
        case .separator: return .separator()
        case .heading(let title): return .sectionHeader(title: title)
        case .new:
            let item = NSMenuItem(title: HomeEngineStrings.computerNew, action: nil, keyEquivalent: "")
            item.tag = newComputerTag
            return item
        case .computer(let title, let target):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = target
            item.image = NSImage(systemSymbolName: target == nil ? "laptopcomputer" : "cloud", accessibilityDescription: nil)
            return item
        }
    }

    /// A machine with a generic name the Chief is using becomes this Chief's computer, once per card.
    private func nameAttachedComputer(_ machine: HomeChiefCloudComputer?) {
        guard let machine, machine.isGenericName, !shownName.isEmpty, namedComputers.insert(machine.id).inserted else { return }
        let chief = shownName
        Task { [weak self] in
            await self?.onNameComputer(machine.id, chief)
            guard let self else { return }
            showComputer(shownComputer)
        }
    }

    /// The Cloud machine id the Chief uses as its computer (engine.json's `machine:<id>`); nil: this Mac or its own computer (`chief:<id>`).
    public var attachedMachine: String? {
        shownComputer.flatMap { $0.hasPrefix("machine:") ? String($0.dropFirst("machine:".count)) : nil }
    }

    /// Makes `target` (engine.json's `computer`: the Chief's own computer, `chief:<id>`) the Chief's Computer Use
    /// computer, as a pick in the picker does; true when the brain took it (the picker shows it).
    func attach(_ target: String) async -> Bool {
        await pick("computer", target).value
        return shownComputer == target
    }

    @objc func pickedComputer(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == Self.newComputerTag {
            showComputer(shownComputer)
            onNewCloudComputer()
            return
        }
        let picked = sender.selectedItem?.representedObject as? String
        guard picked != shownComputer else { return }
        pick("computer", picked ?? "none")
    }

    /// Offers `machines` (the app's Cloud machine list, read at each refresh) and runs the app's own
    /// Cloud actions through `registry`: New Cloud Computer… is `newCloudMachine` (its create card asks
    /// before anything is made or paid), Show Desktop is `cloudOpenDesktop` (the app's Cloud tunnel).
    public func bindCloudComputers(_ registry: ActionRegistry, machines: @escaping @MainActor () -> [HomeChiefCloudComputer]) {
        cloudComputers = machines
        onNewCloudComputer = { [weak self, weak registry] in
            // `chief` names the machine after this Chief (a name `--name` would refuse, with its space).
            let chief = self?.shownName ?? ""
            _ = registry?.perform("newCloudMachine", invocation: ActionInvocation(arguments: chief.isEmpty ? [:] : ["chief": .string(chief)], origin: .user))
        }
        onShowComputerDesktop = { [weak registry] machine in
            let target = ActionTargetRef(kind: .machine, id: machine)
            _ = registry?.perform("cloudOpenDesktop", invocation: ActionInvocation(target: target, origin: .user))
        }
    }

    /// Show Desktop: the attached machine's screen, live in a cmux browser (`cloud open-desktop`).
    @objc func showComputerDesktop() {
        guard let machine = attachedMachine else { return }
        onShowComputerDesktop(machine)
    }
}
