import Foundation

extension CEFEngine {
    /// The shown Chromium page windows by tab and whether each is hosted in the window's layers (fork API 26), as `debug.cef`
    /// `tracker` fields (pixel-perfect, STATUS 13849: `hosted_pages` counts the whole app, so a film arm could not prove which
    /// page was hosted): `hosted.<tab id>` and `hosted.<tab id>.devtools` are 1 when hosted and 0 when not, for each pane page
    /// window and each docked DevTools page window in a window. Read on demand by the debug socket only.
    @MainActor public var hostedPageFields: [String: Double] {
        var fields: [String: Double] = drawOnInputFields
        for host in CEFRuntime.shared.hosts.values {
            guard let tab = host.visibleTab, host.hostView.window != nil else { continue }
            fields["hosted.\(tab.id.rawValue)"] = host.hostView.layerHosting.page != nil ? 1 : 0
            if let devTools = tab.devToolsController.views?.host, devTools.window != nil {
                fields["hosted.\(tab.id.rawValue).devtools"] = devTools.layerHosting.page != nil ? 1 : 0
            }
        }
        return fields
    }

    /// Draw on input (fork API 35, ``CEFDrawOnInput``) as `tracker` fields: `draw_on_input_counter` is 1 when this
    /// engine answers the per-key frame count at all, and `draw_on_input.<browser>` is the frames it drew for keys on
    /// that page. A bench reads a live mode apart from an inert one by them: cmux#45709 shipped the mode against a
    /// pin at fork API 33, where the call is nil and an arm that reads on measures the off path. With the counter at 1
    /// and no `draw_on_input.<browser>` growing, the mode is off or no page is opted in; with it at 0 the engine
    /// cannot draw keys at once whatever the setting reads.
    @MainActor var drawOnInputFields: [String: Double] {
        let mode = CEFRuntime.shared.drawOnInput
        var fields = ["draw_on_input_counter": mode.hasKeyFrames ? 1.0 : 0]
        for (browser, frames) in mode.keyFrames { fields["draw_on_input.\(browser)"] = Double(frames) }
        return fields
    }
}
