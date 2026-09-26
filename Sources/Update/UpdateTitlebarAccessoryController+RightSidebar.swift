import AppKit
import CmuxSettings

/// Right-sidebar accessory lifecycle owned by ``UpdateTitlebarAccessoryController``.
extension UpdateTitlebarAccessoryController {
    /// Reconciles the persisted right-sidebar titlebar-toggle setting.
    func rightSidebarTitlebarAccessoryConfigurationDidChange() -> Bool {
        let current = Self.resolvedRightSidebarTitlebarToggle(defaults: .standard)
        guard current != lastShowsRightSidebarTitlebarToggle else { return false }
        lastShowsRightSidebarTitlebarToggle = current
        return true
    }

    /// Attaches the right-sidebar titlebar accessory when its setting is enabled.
    func attachRightSidebarTitlebarAccessoryIfNeeded(to window: NSWindow) {
        guard Self.resolvedRightSidebarTitlebarToggle(defaults: .standard) else {
            removeRightSidebarTitlebarAccessoryIfPresent(from: window)
            return
        }
        guard !window.titlebarAccessoryViewControllers.contains(where: {
            $0.view.identifier == RightSidebarTitlebarAccessoryViewController.identifier
        }) else {
            return
        }

        let controls = RightSidebarTitlebarAccessoryViewController()
        controls.layoutAttribute = .right
        controls.view.identifier = RightSidebarTitlebarAccessoryViewController.identifier
        window.addTitlebarAccessoryViewController(controls)
    }

    /// Applies presentation-mode visibility to the right-sidebar titlebar accessory.
    func applyRightSidebarTitlebarAccessoryVisibility(
        for window: NSWindow,
        shouldHide: Bool
    ) {
        guard Self.resolvedRightSidebarTitlebarToggle(defaults: .standard) else {
            removeRightSidebarTitlebarAccessoryIfPresent(from: window)
            return
        }
        attachRightSidebarTitlebarAccessoryIfNeeded(to: window)
        for accessory in window.titlebarAccessoryViewControllers
            where accessory.view.identifier == RightSidebarTitlebarAccessoryViewController.identifier {
            accessory.isHidden = shouldHide
            accessory.view.isHidden = shouldHide
            accessory.view.alphaValue = shouldHide ? 0 : 1
        }
    }

    /// Resolves the right-sidebar titlebar-toggle setting for a defaults suite.
    static func resolvedRightSidebarTitlebarToggle(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: RightSidebarChromeSettings.showTitlebarToggleKey) != nil else {
            return RightSidebarChromeSettings.defaultShowTitlebarToggle
        }
        return defaults.bool(forKey: RightSidebarChromeSettings.showTitlebarToggleKey)
    }

    /// Removes the right-sidebar titlebar accessory and requests a titlebar layout pass.
    private func removeRightSidebarTitlebarAccessoryIfPresent(from window: NSWindow) {
        let matchingIndices = window.titlebarAccessoryViewControllers.indices.reversed().filter { index in
            window.titlebarAccessoryViewControllers[index].view.identifier
                == RightSidebarTitlebarAccessoryViewController.identifier
        }
        guard !matchingIndices.isEmpty else { return }
        for index in matchingIndices {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        window.contentView?.needsLayout = true
        window.contentView?.superview?.needsLayout = true
        window.invalidateShadow()
    }
}
