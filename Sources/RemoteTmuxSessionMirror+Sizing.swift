extension RemoteTmuxSessionMirror {
    /// Re-runs the sizing pass on every visible window mirror (used on
    /// reconnect completion): the in-pass container re-validation makes each
    /// pass re-derive its claim from the live window, correcting any size
    /// that went stale across the transport gap.
    func forceResizeAllVisibleMirrors() {
        for mirror in windowMirrorByWindowId.values
        where !mirror.isTornDown && mirror.isVisibleForSizing {
            mirror.setNeedsSizingPassIgnoringInputs()
        }
    }
}
