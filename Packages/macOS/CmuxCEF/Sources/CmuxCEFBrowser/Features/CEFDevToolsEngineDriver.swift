import AppKit
public import CmuxBrowser
import CmuxCEF

/// Chromium DevTools for one browser, driven by ``BrowserDevToolsPaneController``.
///
/// Every way Chromium opens DevTools (these requests, Chromium's own commands, the context
/// menu's Inspect) asks the host for a placement first; the controller answers through
/// ``setDevToolsPlacement(_:)`` while the shim waits.
@MainActor
public final class CEFDevToolsEngineDriver: BrowserDevToolsEngineDriving {
    /// The first fork API whose embedded DevTools activate without recursing (cef `f1d9ec948`).
    public static let embeddedMinimumForkAPI: Int32 = 4

    private let shim: any CEFPageFeatureShim
    private let browserID: @MainActor () -> Int32?

    /// Creates a driver for one browser.
    /// - Parameters:
    ///   - shim: The shim calls.
    ///   - browserID: The inspected page's browser id, `nil` before Chromium created it.
    public init(shim: any CEFPageFeatureShim, browserID: @escaping @MainActor () -> Int32?) {
        self.shim = shim
        self.browserID = browserID
    }

    public var supportsEmbeddedDevTools: Bool {
        shim.forkAPIVersion >= Self.embeddedMinimumForkAPI
    }

    public func runDevToolsRequest(_ request: BrowserDevToolsEngineRequest) {
        guard let browserID = browserID() else { return }
        switch request {
        case .show:
            shim.devToolsCommand(browser: browserID, command: CEFShimLibrary.DevToolsCommand.show.rawValue, x: 0, y: 0)
        case .console:
            shim.devToolsCommand(browser: browserID, command: CEFShimLibrary.DevToolsCommand.console.rawValue, x: 0, y: 0)
        case .inspectElement:
            shim.devToolsCommand(browser: browserID, command: CEFShimLibrary.DevToolsCommand.inspect.rawValue, x: 0, y: 0)
        case .inspectAt(let x, let y):
            shim.devToolsCommand(
                browser: browserID, command: CEFShimLibrary.DevToolsCommand.inspectAt.rawValue,
                x: Int32(clamping: x), y: Int32(clamping: y)
            )
        case .close:
            shim.devToolsCommand(browser: browserID, command: CEFShimLibrary.DevToolsCommand.close.rawValue, x: 0, y: 0)
        }
    }

    public func setDevToolsPlacement(_ placement: BrowserDevToolsPlacement) {
        guard let browserID = browserID() else { return }
        switch placement {
        case .inView(let parent, let size):
            shim.devToolsSetPlacement(
                browser: browserID, parentView: Unmanaged.passUnretained(parent).toOpaque(),
                frame: CGRect(origin: .zero, size: size)
            )
        case .ownWindow(let frame):
            shim.devToolsSetPlacement(browser: browserID, parentView: nil, frame: frame)
        }
    }

    public func setDevToolsFocused(_ focused: Bool) {
        guard let browserID = browserID() else { return }
        guard focused else {
            shim.devToolsSetFocus(browser: browserID, focused: false)
            return
        }
        // Focus makes the DevTools window key, and the pane's key-window
        // handling can ask for focus again before this returns: the shared
        // gate runs that request after this one, as for a page's focus.
        let shim = self.shim
        ChromiumFocusReentrancyGate.shared.runOrDefer { [weak self] in
            guard let self, self.browserID() == browserID else { return }
            shim.devToolsSetFocus(browser: browserID, focused: true)
        }
    }
}
