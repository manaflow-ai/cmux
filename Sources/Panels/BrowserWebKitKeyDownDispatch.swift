import AppKit
import CmuxBrowser
import WebKit

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

@MainActor
extension WKWebView {
    /// Replays a browser automation key through WebKit's native keyboard
    /// pipeline so the page receives a trusted DOM event and its default
    /// editing behavior can run (for example vertical contenteditable motion).
    ///
    /// - Parameters:
    ///   - event: Canonical W3C/Playwright key metadata.
    ///   - action: Whether to send a press, key-down, or key-up.
    /// - Returns: `true` when the key has an AppKit representation and was
    ///   delivered; `false` when the token is outside the native mapping.
    @discardableResult
    func replayBrowserKeyboardEvent(
        _ event: BrowserKeyboardEvent,
        action: BrowserKeyboardAction
    ) -> Bool {
        guard let specification = SyntheticKeyEventFactory.specification(forBrowserEvent: event) else {
            return false
        }
        return replayBrowserKeyboardSpecification(
            specification,
            action: action,
            characters: browserNativeCharacters(for: event)
        )
    }

    /// Delivers an already-resolved AppKit key specification. The mobile
    /// browser stream and socket automation both use this seam so key-down
    /// re-entry handling and event construction cannot diverge.
    @discardableResult
    func replayBrowserKeyboardSpecification(
        _ specification: SyntheticKeySpecification,
        action: BrowserKeyboardAction,
        characters: String? = nil
    ) -> Bool {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: true,
            timestamp: timestamp,
            characters: characters
        )
        let up = SyntheticKeyEventFactory.keyEvent(
            specification: specification,
            keyDown: false,
            timestamp: timestamp,
            characters: characters
        )

        switch action {
        case .press:
            guard let down, let up else { return false }
            deliverBrowserKeyDown(down)
            keyUp(with: up)
        case .keyDown:
            guard let down else { return false }
            deliverBrowserKeyDown(down)
        case .keyUp:
            guard let up else { return false }
            keyUp(with: up)
        }
        return true
    }

    private func deliverBrowserKeyDown(_ event: NSEvent) {
        if let cmuxWebView = self as? CmuxWebView {
            cmuxWebView.forwardKeyDownToWebKit(event)
        } else {
            keyDown(with: event)
        }
    }

    private func browserNativeCharacters(for event: BrowserKeyboardEvent) -> String? {
        guard event.key.utf16.count == 1,
              let codeUnit = event.key.utf16.first,
              codeUnit >= 0x20,
              codeUnit != 0x7F else {
            return nil
        }
        return event.key
    }
}
