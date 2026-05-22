import Foundation
import MinimalBrowserCore
import OwlMojoBindingsGenerated

@MainActor
final class OwlWebContentsController {
    private(set) var tabID: BrowserTab.ID
    private weak var engine: BrowserEngine?

    init(tabID: BrowserTab.ID, engine: BrowserEngine) {
        self.tabID = tabID
        self.engine = engine
    }

    @discardableResult
    func attach(tabID: BrowserTab.ID, engine: BrowserEngine) -> OwlWebContentsAttachmentChange {
        let previousTabID = self.tabID
        self.tabID = tabID
        self.engine = engine
        return OwlWebContentsAttachmentChange(previousTabID: previousTabID, currentTabID: tabID)
    }

    func detach() {
        engine = nil
    }

    func setFocus(_ focused: Bool) {
        engine?.setFocus(tabID: tabID, focused: focused)
    }

    func resize(
        viewport: OwlHostViewport,
        liveResizeCoordinator: OwlLiveResizeCoordinator,
        forceFlush: Bool = false
    ) throws {
        guard let engine else {
            return
        }
        if forceFlush {
            try liveResizeCoordinator.endLiveResize(viewport: viewport, engine: engine, tabID: tabID)
        } else {
            try liveResizeCoordinator.viewportDidChange(viewport, engine: engine, tabID: tabID)
        }
    }

    func pollSurfaceUpdatesForHostGeometry() {
        engine?.pollNowForHostGeometry()
    }

    func sendMouse(_ event: OwlFreshMouseEvent) {
        engine?.sendMouse(tabID: tabID, event: event)
    }

    func sendWheel(_ event: OwlFreshWheelEvent) {
        engine?.sendWheel(tabID: tabID, event: event)
    }

    func sendKey(_ event: OwlFreshKeyEvent) {
        engine?.sendKey(tabID: tabID, event: event)
    }

    func sendComposition(_ event: OwlFreshCompositionEvent) {
        engine?.sendComposition(tabID: tabID, event: event)
    }

    func executeEditCommand(_ command: String) {
        engine?.executeEditCommand(tabID: tabID, command: command)
    }

    func acceptActivePopupMenuItem(index: UInt32) {
        engine?.acceptActivePopupMenuItem(tabID: tabID, index: index)
    }

    func cancelActivePopup() {
        engine?.cancelActivePopup(tabID: tabID)
    }

    func selectActiveFilePickerFiles(paths: [String]) {
        engine?.selectActiveFilePickerFiles(tabID: tabID, paths: paths)
    }

    func cancelActiveFilePicker() {
        engine?.cancelActiveFilePicker(tabID: tabID)
    }

    func acceptActivePermissionPrompt() {
        engine?.acceptActivePermissionPrompt(tabID: tabID)
    }

    func cancelActivePermissionPrompt() {
        engine?.cancelActivePermissionPrompt(tabID: tabID)
    }

    func submitActiveAuthPrompt(username: String, password: String) {
        engine?.submitActiveAuthPrompt(tabID: tabID, username: username, password: password)
    }

    func cancelActiveAuthPrompt() {
        engine?.cancelActiveAuthPrompt(tabID: tabID)
    }

    func closeDevTools() {
        engine?.closeDevTools(tabID: tabID)
    }
}

struct OwlWebContentsAttachmentChange: Equatable {
    let previousTabID: BrowserTab.ID
    let currentTabID: BrowserTab.ID

    var retargetedTab: Bool {
        previousTabID != currentTabID
    }
}
