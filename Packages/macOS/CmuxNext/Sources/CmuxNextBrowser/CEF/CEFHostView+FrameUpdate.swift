import AppKit

/// One tracker update per host per layout (S5, STATUS 13849). The fork's tracker re-places and re-clips a page window on
/// each frame notice of its host and on each geometry post, and reads the occlusion on every update. A layout that sets a
/// host's occlusion and then its frame needs only the frame's notice: between ``beginFrameUpdate()`` and
/// ``endFrameUpdate()`` an occlusion change posts nothing, and the end posts once only when the frame did not change.
extension CEFHostView {
    /// A layout begins that sets this view's occlusion and then its frame.
    func beginFrameUpdate() {
        frameAtUpdate = frame
    }

    /// That layout ended: an occlusion change whose frame stayed posts now (no frame notice told the fork).
    func endFrameUpdate() {
        guard let before = frameAtUpdate else { return }
        let pending = occlusionPostPending
        frameAtUpdate = nil
        occlusionPostPending = false
        if pending, frame == before { postGeometryChange() }
    }
}
