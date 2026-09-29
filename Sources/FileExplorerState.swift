import AppKit
import CmuxFileTree
import SwiftUI

// MARK: - State (visibility toggle)

final class FileExplorerState: ObservableObject {
    private static let modeKey = "rightSidebar.mode"
    private static let customSidebarNameKey = "rightSidebar.customSidebarName"

    @Published var isVisible: Bool {
        didSet { persistVisibility() }
    }
    /// Hidden because the window was too narrow (SidePanelWidthFit), not by the
    /// person. Persisted as visible, so a narrow window neither changes the
    /// default for new windows nor the next launch. Set it before `isVisible`.
    var isAutoCollapsed = false {
        didSet { persistVisibility() }
    }

    private func persistVisibility() {
        UserDefaults.standard.set(isVisible || isAutoCollapsed, forKey: "fileExplorer.isVisible")
    }
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: "fileExplorer.width") }
    }

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    @Published var dividerPosition: CGFloat {
        didSet { UserDefaults.standard.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    /// Whether hidden files (dotfiles and `UF_HIDDEN` items) are shown in the tree.
    ///
    /// Stored under a new key: the legacy `fileExplorer.showHidden` value was
    /// written by an old toggle but ignored for many releases, so honoring it
    /// now could hide dotfiles for people who never chose that.
    @Published var showHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenFilesKey) }
    }

    /// Sibling order for the Files tree.
    @Published var sortOrder: FileTreeSortOrder {
        didSet {
            if let data = try? JSONEncoder().encode(sortOrder) {
                UserDefaults.standard.set(data, forKey: Self.sortOrderKey)
            }
        }
    }

    private static let showHiddenFilesKey = "fileExplorer.showsHiddenFiles.v2"
    private static let sortOrderKey = "fileExplorer.sortOrder.v1"

    @Published private var storedMode: RightSidebarMode
    @Published private var storedCustomSidebarName: String?

    /// Whether the right sidebar (Files / Find / Dock / …) currently owns
    /// keyboard/input focus in this window. Driven by `MainWindowFocusController`
    /// from its exclusive focus `intent`. Used to make main-pane focus and
    /// right-sidebar (Dock) focus mutually exclusive — the main pane dims its
    /// focus ring when the sidebar owns focus, and vice versa. Runtime-only (not
    /// persisted).
    @Published var rightSidebarOwnsInputFocus: Bool = false

    /// The right-sidebar Cloud picker belongs to this window, even before it mounts.
    @MainActor lazy var cloudTeamPickerPresentation = CloudTeamPickerPresentation()

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
        let storedShowHidden = defaults.object(forKey: Self.showHiddenFilesKey)
        self.showHiddenFiles = storedShowHidden == nil ? true : defaults.bool(forKey: Self.showHiddenFilesKey)
        self.sortOrder = defaults.data(forKey: Self.sortOrderKey)
            .flatMap { try? JSONDecoder().decode(FileTreeSortOrder.self, from: $0) } ?? .standard
        let customSidebarName = defaults.string(forKey: Self.customSidebarNameKey)?.nilIfEmpty
        self.storedCustomSidebarName = customSidebarName
        let storedMode = RightSidebarMode.from(cliArgument: defaults.string(forKey: Self.modeKey) ?? "") ?? .files
        self.storedMode = Self.visibleMode(storedMode, defaults: defaults)
        defaults.set(self.storedMode.rawValue, forKey: Self.modeKey)
    }

    /// Re-lands the sidebar on a tab the mode bar shows. Unlike an explicit
    /// `mode` set (which may reveal a user-hidden tab: CLI, palette,
    /// notification routing), restore and preference changes never resurrect a
    /// hidden tab.
    func refreshModeAvailability(defaults: UserDefaults = .standard) {
        setMode(Self.visibleMode(storedMode, defaults: defaults), defaults: defaults)
    }

    func selectCustomSidebar(name rawName: String, defaults: UserDefaults = .standard) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        storedCustomSidebarName = name
        defaults.set(name, forKey: Self.customSidebarNameKey)
    }

    /// The persisted right-sidebar custom-sidebar name, readable without an
    /// instance (mode availability checks run from static contexts).
    static func persistedCustomSidebarName(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customSidebarNameKey)?.nilIfEmpty
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
        mode.isAvailable(defaults: defaults) ? mode : .files
    }

    private static func visibleMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        let candidate = availableMode(mode, defaults: defaults)
        // Custom sidebars are selectable content, not customizable mode-bar tabs.
        if candidate == .customSidebar { return candidate }
        let visible = RightSidebarMode.visibleModes(defaults: defaults)
        if visible.contains(candidate) { return candidate }
        return visible.first ?? candidate
    }
}
