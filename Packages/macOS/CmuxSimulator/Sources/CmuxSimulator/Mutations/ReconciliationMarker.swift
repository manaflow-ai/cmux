struct ReconciliationMarker: Codable {
    let phase: ReconciliationPhase
    let legacyRecord: SimulatorCameraAuthorizationRecord?
    let durableRecord: SimulatorCameraAuthorizationRecord?
}
