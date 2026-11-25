import Foundation

extension CEFEngine {
    /// The shown Chromium page windows by tab and whether each is hosted in the window's layers (fork API 26), as `debug.cef`
    /// `tracker` fields (pixel-perfect, STATUS 13849: `hosted_pages` counts the whole app, so a film arm could not prove which
    /// page was hosted): `hosted.<tab id>` and `hosted.<tab id>.devtools` are 1 when hosted and 0 when not, for each pane page
    /// window and each docked DevTools page window in a window. Read on demand by the debug socket only.
    public var hostedPageFields: [String: Double] {
        var fields: [String: Double] = [:]
        for host in CEFRuntime.shared.hosts.values {
            guard let tab = host.visibleTab, host.hostView.window != nil else { continue }
            fields["hosted.\(tab.id.rawValue)"] = host.hostView.layerHosting.page != nil ? 1 : 0
            if let devTools = tab.devToolsController.views?.host, devTools.window != nil {
                fields["hosted.\(tab.id.rawValue).devtools"] = devTools.layerHosting.page != nil ? 1 : 0
            }
        }
        return fields
    }
}
