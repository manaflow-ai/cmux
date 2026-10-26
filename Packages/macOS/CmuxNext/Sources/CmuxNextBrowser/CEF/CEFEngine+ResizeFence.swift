extension CEFEngine {
    /// Feature `cefResizeFence`: on a fork with the resize fence, page resizes sync through one Core
    /// Animation fence per transaction (``CEFResizeFences``); off keeps the API 27 resize deadlines.
    /// Applies to page windows made from now on; an open transaction keeps its fence. Returns self.
    @discardableResult
    public func usingResizeFence(_ enabled: Bool) -> CEFEngine {
        let runtime = CEFRuntime.shared
        runtime.resizeFences = enabled ? (runtime.resizeFences ?? CEFResizeFences()) : nil
        return self
    }
}
