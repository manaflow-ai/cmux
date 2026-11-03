import AppKit

/// Turns a ``ChiefTeleportMenu`` into the `NSMenu` the location chip pops up: a title, the
/// destinations (the current one checked), Roll Back while the home is moved, and the running or
/// last move's line. A pick calls the model's ``ChiefTeleportModel/onMove`` or
/// ``ChiefTeleportModel/onRollback`` (the app's `chief.moveTo` and `chief.moveRollback`).
@MainActor
final class ChiefTeleportMenuBuilder: NSObject {
    private let model: ChiefTeleportModel

    init(model: ChiefTeleportModel) {
        self.model = model
    }

    /// The menu for the model as it is now.
    func makeMenu() -> NSMenu {
        let contents = model.menu()
        let menu = NSMenu(title: ChiefTeleportStrings.menuTitle)
        menu.autoenablesItems = false
        let header = NSMenuItem(title: ChiefTeleportStrings.menuTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for row in contents.rows {
            let item = NSMenuItem(title: row.title, action: #selector(pickDestination(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.state = row.state == .current ? .on : .off
            item.isEnabled = row.state == .available
            item.setAccessibilityIdentifier("cmux.home.chief.teleport.\(row.id)")
            menu.addItem(item)
        }
        if let rollback = contents.rollback {
            menu.addItem(.separator())
            let item = NSMenuItem(title: ChiefTeleportStrings.rollback, action: #selector(pickRollback), keyEquivalent: "")
            item.target = self
            item.isEnabled = rollback == .available
            item.setAccessibilityIdentifier("cmux.home.chief.teleport.rollback")
            menu.addItem(item)
        }
        if let status = Self.statusLine(model.phase) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    /// The menu's last line for a running or finished move; nil before the first one.
    static func statusLine(_ phase: ChiefTeleportPhase) -> String? {
        switch phase {
        case .idle: nil
        case .checking(let name): ChiefTeleportStrings.checking(name)
        case .moving(let name): ChiefTeleportStrings.moving(name)
        case .verifying(let name): ChiefTeleportStrings.verifying(name)
        case .done(let name): ChiefTeleportStrings.done(name)
        case .failed(let name, _): ChiefTeleportStrings.failed(name)
        case .rollingBack: ChiefTeleportStrings.rollingBack
        case .rolledBack: ChiefTeleportStrings.rolledBack
        }
    }

    @objc private func pickDestination(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.onMove(id)
    }

    @objc private func pickRollback() {
        model.onRollback()
    }
}
