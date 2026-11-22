import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign

/// A pull-down titled "3 of 4 profiles"; each profile is a checkable item.
/// With nothing found it shows the calm line instead (disabled).
final class ImportProfileMenu: NSPopUpButton {
    private let model: ImportStepModel
    private var loop: RenderLoop?

    init(model: ImportStepModel) {
        self.model = model
        super.init(frame: .zero, pullsDown: true)
        translatesAutoresizingMaskIntoConstraints = false
        controlSize = .large
        loop = RenderLoop { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? BrowserSourceProfile else { return }
        model.toggle(profile)
    }

    private func render() {
        let menu = NSMenu()
        let title = NSMenuItem(title: ImportKit.emptyText(model) ?? ImportKit.countText(model), action: nil, keyEquivalent: "")
        menu.addItem(title)
        for profile in model.profiles {
            let item = NSMenuItem(title: OnboardingStrings.profileName(profile), action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.state = model.isSelected(profile) ? .on : .off
            menu.addItem(item)
        }
        self.menu = menu
        isEnabled = model.canEditSelection && !model.profiles.isEmpty
    }
}
