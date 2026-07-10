import Observation
import AppKit
import SwiftUI

// MARK: - State (visibility toggle)

@Observable
final class FileExplorerState {
    private static let modeKey = "rightSidebar.mode"
    private static let customSidebarNameKey = "rightSidebar.customSidebarName"

    var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "fileExplorer.isVisible") }
    }
    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: "fileExplorer.width") }
    }

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    var dividerPosition: CGFloat {
        didSet { UserDefaults.standard.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    /// Whether hidden files (dotfiles) are shown in the tree.
    var showHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: "fileExplorer.showHidden") }
    }

    private var storedMode: RightSidebarMode
    private var storedCustomSidebarName: String?

    /// Whether the right sidebar (Files / Find / Dock / …) currently owns
    /// keyboard/input focus in this window. Driven by `MainWindowFocusController`
    /// from its exclusive focus `intent`. Used to make main-pane focus and
    /// right-sidebar (Dock) focus mutually exclusive — the main pane dims its
    /// focus ring when the sidebar owns focus, and vice versa. Runtime-only (not
    /// persisted).
    var rightSidebarOwnsInputFocus: Bool = false

    /// Active mode for the right sidebar (file tree, search, sessions, or enabled beta modes).
    var mode: RightSidebarMode {
        get { storedMode }
        set { setMode(newValue) }
    }

    var customSidebarName: String? {
        storedCustomSidebarName
    }

    init() {
        let defaults = UserDefaults.standard
        self.isVisible = defaults.bool(forKey: "fileExplorer.isVisible")
        let storedWidth = defaults.double(forKey: "fileExplorer.width")
        self.width = storedWidth > 0 ? CGFloat(storedWidth) : 220
        let storedPosition = defaults.double(forKey: "fileExplorer.dividerPosition")
        self.dividerPosition = storedPosition > 0 ? CGFloat(storedPosition) : 0.6
        let storedShowHidden = defaults.object(forKey: "fileExplorer.showHidden")
        self.showHiddenFiles = storedShowHidden == nil ? true : defaults.bool(forKey: "fileExplorer.showHidden")
        let customSidebarName = defaults.string(forKey: Self.customSidebarNameKey)?.nilIfEmpty
        self.storedCustomSidebarName = customSidebarName
        let storedMode = RightSidebarMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .files
        self.storedMode = Self.availableMode(storedMode, defaults: defaults)
        defaults.set(self.storedMode.rawValue, forKey: Self.modeKey)
    }

    func refreshModeAvailability(defaults: UserDefaults = .standard) {
        setMode(storedMode, defaults: defaults)
    }

    func selectCustomSidebar(name rawName: String, defaults: UserDefaults = .standard) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        storedCustomSidebarName = name
        defaults.set(name, forKey: Self.customSidebarNameKey)
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard isVisible != nextValue else { return }

        // Suppress both SwiftUI transactions and AppKit/Core Animation implicit layout changes.
        NSAnimationContext.beginGrouping()
        CATransaction.begin()
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.setDisableActions(true)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isVisible = nextValue
        }
    }

    private func setMode(_ mode: RightSidebarMode, defaults: UserDefaults = .standard) {
        let nextMode = Self.availableMode(mode, defaults: defaults)
        guard storedMode != nextMode else {
            if defaults.string(forKey: Self.modeKey) != nextMode.rawValue {
                defaults.set(nextMode.rawValue, forKey: Self.modeKey)
            }
            return
        }
        storedMode = nextMode
        defaults.set(nextMode.rawValue, forKey: Self.modeKey)
    }

    private static func availableMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        if mode == .customSidebar {
            return .files
        }
        return mode.isAvailable(defaults: defaults) ? mode : .files
    }
}
