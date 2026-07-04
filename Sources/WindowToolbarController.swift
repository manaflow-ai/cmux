import AppKit
import Combine
import CmuxFoundation
import SwiftUI

@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let commandItemIdentifier = NSToolbarItem.Identifier("cmux.focusedCommand")
    private let layoutModeItemIdentifier = NSToolbarItem.Identifier("cmux.layoutMode")

    private weak var tabManager: TabManager?

    private var commandLabels: [ObjectIdentifier: NSTextField] = [:]
    private var layoutModeControls: [ObjectIdentifier: NSSegmentedControl] = [:]
    private var observers: [NSObjectProtocol] = []
    private let focusedCommandUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()

    override init() {
        super.init()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start(tabManager: TabManager) {
        self.tabManager = tabManager
        attachToExistingWindows()
        installObservers()
        scheduleFocusedCommandTextUpdate()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changedWorkspaceId = GhosttyTitleChange(notification: notification)?.tabId
            Task { @MainActor [weak self, changedWorkspaceId] in
                guard let self,
                      self.tabManager?.shouldScheduleRawTitleRefresh(forWorkspaceId: changedWorkspaceId) == true else { return }
                self.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: .workspaceTitleDidChange,
            object: tabManager,
            queue: .main
        ) { [weak self] notification in
            let changedWorkspaceId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID
            Task { @MainActor [weak self, changedWorkspaceId] in
                guard let self, changedWorkspaceId == self.tabManager?.selectedTabId, self.tabManager?.shouldScheduleRawTitleRefresh(forWorkspaceId: changedWorkspaceId) == false else { return }
                self.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidFocusTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
                self?.updateLayoutModeSelection()
            }
        })

        observers.append(center.addObserver(
            forName: .workspaceLayoutModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLayoutModeSelection()
            }
        })

        // A grouped anchor's command label name is derived from its group's
        // name, so a group rename must refresh the label text (#5404). Scope to
        // this controller's own `tabManager` (the notification's `object`) so a
        // rename in another window doesn't spuriously refresh this one.
        observers.append(center.addObserver(
            forName: .workspaceGroupNameDidChange,
            object: tabManager,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                self?.attach(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateToolbarVisibilityIfNeeded()
            }
        })

        observers.append(center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCommandLabelFont()
            }
        })
    }

    private func updateToolbarVisibilityIfNeeded() {
        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode
        let isMinimal = currentMode == .minimal
        for window in NSApp.windows {
            if isMinimal {
                window.toolbar = nil
            } else {
                attach(to: window)
            }
        }
        // After toolbar changes, force titlebar accessories to recalculate.
        // Toolbar removal/re-addition changes the titlebar geometry, and
        // accessories hidden via isHidden need a layout pass to reappear.
        if !isMinimal {
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    for accessory in window.titlebarAccessoryViewControllers {
                        if !accessory.isHidden {
                            accessory.view.needsLayout = true
                            accessory.view.superview?.needsLayout = true
                        }
                    }
                    window.contentView?.needsLayout = true
                    window.contentView?.superview?.needsLayout = true
                    window.invalidateShadow()
                }
            }
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attach(to: window)
        }
    }

    private func attach(to window: NSWindow) {
        guard window.toolbar == nil else { return }
        guard !WorkspacePresentationModeSettings.isMinimal() else { return }
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cmux.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
    }

    private func scheduleFocusedCommandTextUpdate() {
        focusedCommandUpdateCoalescer.signal { [weak self] in
            self?.updateFocusedCommandText()
        }
    }

    private func updateFocusedCommandText() {
        guard let tabManager else { return }
        let text: String
        if let selectedId = tabManager.selectedTabId,
           let tab = tabManager.tabs.first(where: { $0.id == selectedId }) {
            let title = tabManager.resolvedWorkspaceDisplayTitle(for: tab)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            text = title.isEmpty ? "Cmd: —" : "Cmd: \(title)"
        } else {
            text = "Cmd: —"
        }

        for label in commandLabels.values {
            if label.stringValue != text {
                label.stringValue = text
            }
        }
    }

    private func applyCommandLabelFont() {
        let font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .medium)
        for label in commandLabels.values {
            label.font = font
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [layoutModeItemIdentifier, commandItemIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [layoutModeItemIdentifier, commandItemIdentifier, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == commandItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "Cmd: —")
            label.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            item.view = label
            commandLabels[ObjectIdentifier(toolbar)] = label
            scheduleFocusedCommandTextUpdate()
            return item
        }

        if itemIdentifier == layoutModeItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let segmented = NSSegmentedControl()
            segmented.segmentStyle = .texturedRounded
            segmented.trackingMode = .selectOne
            segmented.segmentCount = 2
            segmented.controlSize = .small
            segmented.setImage(
                LayoutModeToolbarImages.splits,
                forSegment: LayoutModeSegment.splits.rawValue
            )
            segmented.setImage(
                LayoutModeToolbarImages.canvas,
                forSegment: LayoutModeSegment.canvas.rawValue
            )
            segmented.setToolTip(
                String(localized: "toolbar.layout.splits", defaultValue: "Split panes"),
                forSegment: LayoutModeSegment.splits.rawValue
            )
            segmented.setToolTip(
                String(localized: "toolbar.layout.canvas", defaultValue: "Canvas"),
                forSegment: LayoutModeSegment.canvas.rawValue
            )
            segmented.target = self
            segmented.action = #selector(layoutModeSegmentChanged(_:))
            item.view = segmented
            item.label = String(localized: "toolbar.layout.label", defaultValue: "Layout")
            item.toolTip = String(localized: "shortcut.toggleCanvasLayout.label", defaultValue: "Toggle Canvas Layout")
            layoutModeControls[ObjectIdentifier(toolbar)] = segmented
            updateLayoutModeSelection()
            return item
        }

        return nil
    }

    // MARK: - Layout mode toggle

    private enum LayoutModeSegment: Int {
        case splits = 0
        case canvas = 1
    }

    @objc private func layoutModeSegmentChanged(_ sender: NSSegmentedControl) {
        guard let workspace = tabManager?.selectedWorkspace else { return }
        let target: WorkspaceLayoutMode = sender.selectedSegment == LayoutModeSegment.canvas.rawValue ? .canvas : .splits
        workspace.setLayoutMode(target)
    }

    private func updateLayoutModeSelection() {
        let mode = tabManager?.selectedWorkspace?.layoutMode ?? .splits
        let segment = mode == .canvas ? LayoutModeSegment.canvas.rawValue : LayoutModeSegment.splits.rawValue
        for control in layoutModeControls.values where control.selectedSegment != segment {
            control.selectedSegment = segment
        }
    }

}

@MainActor
private enum LayoutModeToolbarImages {
    static let splits = makeImage { rect in
        let outer = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        outer.lineWidth = 1.4
        outer.stroke()

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.midX, y: rect.minY + 1.0))
        divider.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1.0))
        divider.lineWidth = 1.2
        divider.stroke()
    }

    static let canvas = makeImage { rect in
        let backRect = NSRect(
            x: rect.minX + 1.0,
            y: rect.minY + 1.0,
            width: rect.width - 5.0,
            height: rect.height - 5.0
        )
        let frontRect = NSRect(
            x: rect.minX + 5.0,
            y: rect.minY + 5.0,
            width: rect.width - 5.0,
            height: rect.height - 5.0
        )

        let back = NSBezierPath(roundedRect: backRect, xRadius: 2.0, yRadius: 2.0)
        back.lineWidth = 1.2
        back.stroke()

        let front = NSBezierPath(roundedRect: frontRect, xRadius: 2.0, yRadius: 2.0)
        front.lineWidth = 1.4
        front.stroke()
    }

    private static func makeImage(draw: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { bounds in
            // macOS 27 betas can throw while CoreUI rasterizes named SF Symbol
            // glyphs inside titlebar toolbar controls. These local template
            // images keep the toolbar off that code path.
            NSGraphicsContext.current?.shouldAntialias = true
            NSColor.black.setStroke()
            draw(bounds.insetBy(dx: 1.5, dy: 1.5))
            return true
        }
        image.isTemplate = true
        return image
    }
}
