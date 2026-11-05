import AppKit
public import CmuxNextActions
import CmuxNextDesign

/// One Cloud machine the card's Computer picker offers (cmux issue 36047).
public nonisolated struct HomeChiefCloudComputer: Equatable, Sendable {
    /// The Cloud machine id (`cmux cloud list-machines`' `machine_id`).
    public var id: String
    /// The machine's name, as the sidebar shows it.
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
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
        computerRow.addArrangedSubview(Self.sectionHeader(HomeEngineStrings.computerSection))
        computerPicker.target = self
        computerPicker.action = #selector(pickedComputer(_:))
        computerPicker.font = Typography.body
        computerPicker.setAccessibilityLabel(HomeEngineStrings.computerRow)
        computerPicker.setAccessibilityIdentifier("cmux.home.chief.computer")
        let row = Self.row(HomeEngineStrings.computerRow, computerPicker)
        computerRow.addArrangedSubview(row)
        computerNote.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        computerRow.addArrangedSubview(computerNote)
        computerDesktop.setAccessibilityIdentifier("cmux.home.chief.computerDesktop")
        computerRow.addArrangedSubview(computerDesktop)
        addFullWidth(computerRow)
        row.widthAnchor.constraint(equalTo: computerRow.widthAnchor).isActive = true
        stack.setCustomSpacing(Metrics.space4, after: computerRow)
        computerRow.isHidden = !source.isLocal
        showComputer(nil)
    }

    /// Fills the picker for `computer` (engine.json's `machine:<id>`, nil: this Mac). A machine the
    /// list no longer has (deleted, or the list still loading) stays shown by its id. Items are added
    /// as menu items, never by title: two machines may share a name (`addItem(withTitle:)` keeps one).
    func showComputer(_ computer: String?) {
        shownComputer = computer
        let machines = cloudComputers()
        let menu = NSMenu()
        func add(_ title: String, _ target: String?, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = target
            item.tag = tag
            menu.addItem(item)
        }
        add(HomeEngineStrings.computerThisMac, nil)
        for machine in machines { add(machine.title, machine.target) }
        if let computer, !machines.contains(where: { $0.target == computer }) { add(computer, computer) }
        menu.addItem(.separator())
        add(HomeEngineStrings.computerNew, nil, tag: Self.newComputerTag)
        computerPicker.menu = menu
        let index = computer.flatMap { target in menu.items.firstIndex { ($0.representedObject as? String) == target } } ?? 0
        computerPicker.selectItem(at: index)
        // A Chief that moved off this Mac keeps the computer it took here: its row stays while one is
        // set, so the owner can still detach it.
        let hidden = !source.isLocal && computer == nil
        if computerRow.isHidden != hidden { computerRow.isHidden = hidden }
        let attached = computer != nil
        computerNote.stringValue = attached ? HomeEngineStrings.computerCloudNote : HomeEngineStrings.computerMacNote
        if computerDesktop.isHidden == attached { computerDesktop.isHidden = !attached }
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
        onNewCloudComputer = { [weak registry] in
            _ = registry?.perform("newCloudMachine", invocation: ActionInvocation(origin: .user))
        }
        onShowComputerDesktop = { [weak registry] machine in
            let target = ActionTargetRef(kind: .machine, id: machine)
            _ = registry?.perform("cloudOpenDesktop", invocation: ActionInvocation(target: target, origin: .user))
        }
    }

    /// Show Desktop: the attached machine's screen, live in a cmux browser (`cloud open-desktop`).
    @objc func showComputerDesktop() {
        guard let target = shownComputer else { return }
        onShowComputerDesktop(String(target.dropFirst("machine:".count)))
    }
}
