extension CEFEngine {
    /// Feature `cefLayerHosting`: a pane's page hosts in the window's layers where the app makes every Track A
    /// call (`CEFLayerHosting.TrackA`). Applies to page windows made from now on; keeps the calls already made.
    @discardableResult
    public func usingLayerHostingByDefault(_ enabled: Bool) -> CEFEngine {
        let runtime = CEFRuntime.shared
        runtime.pageHosting.trackA = enabled ? (runtime.pageHosting.trackA ?? []) : nil
        return self
    }

    /// Feature `cefAttachedPages`: a pane's tabs attach Chromium's own view in the pane
    /// where the fork has the call (`CEFAttachedPages`). Applies to page windows made from now on.
    @discardableResult
    public func usingAttachedPages(_ enabled: Bool) -> CEFEngine {
        CEFRuntime.shared.pageHosting.attachesViews = enabled
        return self
    }
}
