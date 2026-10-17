import AppKit
import CmuxNextDesign

/// Debug menu > Motion (DEV and NIGHTLY): quickly exercises animation speed
/// and Reduce Motion variants without writing the user's settings file.
final class MotionDebugMenu: NSObject, NSMenuDelegate {
    static let shared = MotionDebugMenu()

    private enum Choice: String {
        case fast, normal, off
        case reduceSystem, reduceEnabled, reduceDisabled
    }

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: Strings.menuMotion, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: Strings.menuMotion)
        menu.delegate = self
        let speed = submenu(Strings.menuMotionSpeed, choices: [
            (Strings.menuMotionFast, .fast), (Strings.menuMotionNormal, .normal), (Strings.menuMotionOff, .off),
        ])
        menu.addItem(speed)
        menu.addItem(.separator())
        let reduce = submenu(Strings.menuMotionReduceMotion, choices: [
            (Strings.menuMotionFollowSystem, .reduceSystem),
            (Strings.menuMotionEnabled, .reduceEnabled),
            (Strings.menuMotionDisabled, .reduceDisabled),
        ])
        menu.addItem(reduce)
        updateStates(in: menu)
        item.submenu = menu
        return item
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = Choice(rawValue: raw) else { return }
        switch choice {
        case .fast: DesignSettings.shared.animationSpeed = .fast
        case .normal: DesignSettings.shared.animationSpeed = .normal
        case .off: DesignSettings.shared.animationSpeed = .off
        case .reduceSystem: Motion.reduceMotionOverride = nil
        case .reduceEnabled: Motion.reduceMotionOverride = true
        case .reduceDisabled: Motion.reduceMotionOverride = false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateStates(in: menu) }

    private func submenu(_ title: String, choices: [(String, Choice)]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        for (label, choice) in choices {
            let child = NSMenuItem(title: label, action: #selector(choose(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = choice.rawValue
            menu.addItem(child)
        }
        item.submenu = menu
        return item
    }

    private func updateStates(in menu: NSMenu) {
        let reduceChoice: Choice = switch Motion.reduceMotionOverride {
        case nil: .reduceSystem
        case true: .reduceEnabled
        case false: .reduceDisabled
        }
        for item in menu.items {
            if let raw = item.representedObject as? String {
                let choice = Choice(rawValue: raw)
                item.state = (choice == reduceChoice || choice?.rawValue == DesignSettings.shared.animationSpeed.rawValue) ? .on : .off
            }
            if let submenu = item.submenu { updateStates(in: submenu) }
        }
    }
}
