extension CEFEngine {
    /// Feature `cefLayerHosting`: a pane's page hosts in the window's layers where the app makes every Track A
    /// call (`CEFLayerHosting.TrackA`). Applies to page windows made from now on; keeps the calls already made.
    @discardableResult
    public func usingLayerHostingByDefault(_ enabled: Bool) -> CEFEngine {
        let runtime = CEFRuntime.shared
        runtime.layerHostingTrackA = enabled ? (runtime.layerHostingTrackA ?? []) : nil
        return self
    }
}
