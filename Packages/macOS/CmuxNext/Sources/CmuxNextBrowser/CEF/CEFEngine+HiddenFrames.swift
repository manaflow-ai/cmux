extension CEFEngine {
    /// The app-wide list of hidden frames (`HiddenFrameLRU`, built in AppServices) that decides how long a
    /// hidden hosted page keeps its last frame for its next show. Applies to page windows made from now on.
    @discardableResult
    public func usingHiddenFrames(_ frames: any CEFHiddenFrames) -> CEFEngine {
        CEFRuntime.shared.hiddenFrames = frames
        return self
    }
}
