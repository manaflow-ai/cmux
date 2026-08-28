import Foundation

@testable import CmuxSidebar

/// Records focus-handler installs and removals so a test can assert actual absence.
///
/// `WKUserContentController` cannot be asked what it holds, so without this the only available
/// check is "re-install and see whether it trapped" — which passes identically when nothing was ever
/// registered, i.e. it cannot fail for the reason that matters.
@MainActor
final class CustomSidebarFocusHandlerRegistrySpy: CustomSidebarFocusHandlerRegistering {
    /// The handler currently registered, or `nil` when none is.
    private(set) var installed: CustomSidebarFocusBridge?
    /// Every install, in order, so a same-source update can be shown not to re-register.
    private(set) var installCount = 0
    /// Every removal, in order.
    private(set) var removeCount = 0

    func installFocusHandler(_ bridge: CustomSidebarFocusBridge) {
        installed = bridge
        installCount += 1
    }

    func removeFocusHandler() {
        installed = nil
        removeCount += 1
    }
}
