public import AppKit
public import CmuxNextDesign

/// Command + scroll over a Chromium page goes to the page first when the page uses it
/// (`layout.pagesHandleCommandScroll`): the layout asks here, once per gesture.
extension CEFEngine: PageCommandScrollArbiter {
    public func pageHandlesCommandScroll(in window: NSWindow, at locationInWindow: NSPoint) async -> Bool {
        let runtime = CEFRuntime.shared
        let screenPoint = window.convertPoint(toScreen: locationInWindow)
        guard let browser = CEFLinkClicks.browser(clickedIn: ObjectIdentifier(window), parent: window.parent.map(ObjectIdentifier.init),
                                                  at: screenPoint, targets: runtime.windowRequests.clickTargets()),
              let tab = runtime.tabsByBrowser[browser],
              let host = runtime.hosts.values.first(where: { $0.visibleTab === tab })?.hostView,
              let hostWindow = host.window else { return false }
        let point = host.convert(hostWindow.convertPoint(fromScreen: screenPoint), from: nil)
        let zoom = max(CGFloat(tab.state.zoom), 0.25)
        let probe = BrowserCommandScrollProbe()
        let script = probe.script(x: point.x / zoom, y: (host.bounds.height - point.y) / zoom)
        guard let value = try? await tab.evaluate(script, world: .page, gesture: .cmux) else { return false }
        return probe.handles(value)
    }
}
