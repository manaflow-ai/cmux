import Foundation

extension CEFRuntime {
    /// Layer hosting of every live host view now (`debug.cef` `layer_hosting`):
    /// each pane host's view and each docked DevTools view. Read from the
    /// runtime's own hosts and tabs, so no global count can drift.
    var layerHostingReport: CEFLayerHostingReport {
        let panes = hosts.values.map(\.hostView.layerHosting)
        let devTools = tabsByBrowser.values.compactMap { $0.devToolsController.views?.host.layerHosting }
        return CEFLayerHostingReport(hostings: panes + devTools)
    }
}
