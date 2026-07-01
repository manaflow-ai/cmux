import AppKit

@MainActor
private var cmuxBrowserWebKitKeyDownDispatchDepth = 0

@MainActor
func cmuxBrowserWebKitKeyDownDispatchIsActive() -> Bool {
    cmuxBrowserWebKitKeyDownDispatchDepth > 0
}

@MainActor
func cmuxWithBrowserWebKitKeyDownDispatch<T>(_ body: () -> T) -> T {
    cmuxBrowserWebKitKeyDownDispatchDepth += 1
    defer {
        cmuxBrowserWebKitKeyDownDispatchDepth = max(0, cmuxBrowserWebKitKeyDownDispatchDepth - 1)
    }
    return body()
}

@MainActor
extension CmuxWebView {
    func forwardKeyDownToWebKit(_ event: NSEvent) {
        cmuxWithBrowserWebKitKeyDownDispatch {
            super.keyDown(with: event)
        }
    }
}
