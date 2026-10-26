extension PageWebView {
    /// The page's side of a discard (p13-webui-088). It makes no call into the page, which may be
    /// frozen and could not answer: the shell keeps what the page gave when it hid, the state it saved
    /// (``PageHideState/savedState``) and the picture of its last frame, which is encoded now off the
    /// main thread so the decoded frame can go. Ending the engine page is p13-webui-030's step.
    ///
    /// - Parameter encoder: Encodes a WebKit frame (a Chromium picture comes encoded).
    func discardDocument(encoder: PageSnapshotEncoder) {
        hideState.encodeForDiscard(with: encoder)
    }
}
