/// Opaque carrier for the app-side process-detected resume indexes
/// (`RestorableAgentSessionIndex` + `SurfaceResumeBindingIndex`).
///
/// The coordinator passes the resume indexes through the autosave/save flow
/// (load once, reuse for fingerprint and the actual save) without naming the
/// app-target index types. The host loads them, hands back this carrier, and
/// unwraps it inside its own `saveSessionSnapshot` / `sessionAutosaveFingerprint`
/// witnesses. `payload` is `@unchecked Sendable`-free: it stores the app's
/// already-`Sendable` index values behind `Any`, and only the main-actor host
/// reads them back, mirroring the legacy `ProcessDetectedResumeIndexes` value
/// the autosave tick threaded through.
public struct AppSessionResumeIndexes: Sendable {
    /// The boxed app-side indexes. The app conforms its index pair to
    /// ``AppSessionResumeIndexCarrying`` and stuffs it here; the coordinator
    /// never inspects it.
    public let payload: any AppSessionResumeIndexCarrying

    /// Wraps the app-side resume-index payload.
    public init(payload: any AppSessionResumeIndexCarrying) {
        self.payload = payload
    }
}

/// Marker the app's resume-index value type conforms to so it can ride inside
/// ``AppSessionResumeIndexes`` opaquely. The app type already holds only
/// `Sendable` index values, so the conformance is `Sendable`-clean.
public protocol AppSessionResumeIndexCarrying: Sendable {}
