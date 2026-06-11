import AppKit

private var cmuxBrowserWebKitKeyDownDispatchDepth = 0

func cmuxBrowserWebKitKeyDownDispatchIsActive() -> Bool {
    cmuxBrowserWebKitKeyDownDispatchDepth > 0
}

func cmuxWithBrowserWebKitKeyDownDispatch<T>(_ body: () -> T) -> T {
    cmuxBrowserWebKitKeyDownDispatchDepth += 1
    defer {
        cmuxBrowserWebKitKeyDownDispatchDepth = max(0, cmuxBrowserWebKitKeyDownDispatchDepth - 1)
    }
    return body()
}

extension CmuxWebView {
    func forwardKeyDownToWebKit(_ event: NSEvent) {
        cmuxWithBrowserWebKitKeyDownDispatch {
            super.keyDown(with: event)
        }
    }
}
