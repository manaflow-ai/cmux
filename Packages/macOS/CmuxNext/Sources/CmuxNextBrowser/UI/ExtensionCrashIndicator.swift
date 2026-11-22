import AppKit

/// "Extension crashed, click to reload": while an extension of
/// the tab's profile is terminated (its process crashed or was killed), the
/// toolbar shows a warning button before the Extensions button. Clicking it
/// reloads every crashed extension.
@MainActor
final class ExtensionCrashIndicator {
    static let identifier = "browser.extensions.crashed"
    private let trampoline = MenuTrampoline()
    private weak var store: BrowserExtensionStore?
    private(set) lazy var button: ChromeIconButton = {
        let button = ChromeIconButton(symbol: "exclamationmark.triangle", label: "",
                                      action: #selector(MenuTrampoline.fire), target: trampoline, toolbar: true)
        button.setAccessibilityIdentifier(Self.identifier)
        return button
    }()

    init() {
        trampoline.action = { [weak self] in self?.reloadCrashed() }
    }

    /// Shows or hides the button in `slot`, just before `puzzle`.
    func update(store: BrowserExtensionStore?, in slot: NSStackView, before puzzle: NSView) {
        self.store = store
        let crashed = store?.crashed ?? []
        let arranged = slot.arrangedSubviews.contains(button)
        guard !crashed.isEmpty else {
            if arranged {
                slot.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
            return
        }
        button.setSymbol("exclamationmark.triangle", label: Strings.extensionsCrashed(crashed.map(\.name)))
        let target = slot.arrangedSubviews.firstIndex(of: puzzle) ?? slot.arrangedSubviews.count
        if let current = slot.arrangedSubviews.firstIndex(of: button), current == target - 1 { return }
        if arranged { slot.removeArrangedSubview(button) }
        slot.insertArrangedSubview(button, at: slot.arrangedSubviews.firstIndex(of: puzzle) ?? slot.arrangedSubviews.count)
    }

    /// The crashed extensions the button reloads (tests, debug).
    var crashedNames: [String] { store?.crashed.map(\.name) ?? [] }

    func reloadCrashed() {
        guard let store else { return }
        for info in store.crashed { _ = store.reload(info.id) }
    }
}
