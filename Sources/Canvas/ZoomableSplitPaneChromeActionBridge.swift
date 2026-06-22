import AppKit

@MainActor
struct ZoomableSplitPaneChromeActionBridge {
    let rootView: ZoomableSplitRootView
    let documentView: NSView
    weak var workspace: Workspace?

    @discardableResult
    func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        let rootPoint = rootView.convert(event.locationInWindow, from: nil)
        guard rootView.bounds.contains(rootPoint) else { return false }
        let documentPoint = documentView.convert(rootPoint, from: rootView)
        guard let workspace,
              let hit = ZoomableSplitRootView.splitActionButtonHit(
                atDocumentPoint: documentPoint,
                in: workspace.bonsplitController.layoutSnapshot(),
                appearance: workspace.bonsplitController.configuration.appearance
              ) else {
            return false
        }

        workspace.bonsplitController.focusPane(hit.paneId)
        switch hit.button.action {
        case .newTerminal:
            workspace.bonsplitController.requestNewTab(kind: "terminal", inPane: hit.paneId)
        case .newBrowser:
            workspace.bonsplitController.requestNewTab(kind: "browser", inPane: hit.paneId)
        case .splitRight:
            _ = workspace.bonsplitController.splitPane(hit.paneId, orientation: .horizontal)
        case .splitDown:
            _ = workspace.bonsplitController.splitPane(hit.paneId, orientation: .vertical)
        case .custom(let identifier):
            workspace.bonsplitController.requestCustomAction(identifier, inPane: hit.paneId)
        }
        return true
    }
}
