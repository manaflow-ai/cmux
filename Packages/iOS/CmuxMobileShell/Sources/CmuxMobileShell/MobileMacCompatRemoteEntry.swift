/// One wire-format iOS tier from the remote Mac compatibility list.
struct MobileMacCompatRemoteEntry: Decodable {
    let minIOSVersion: String
    let maxIOSVersion: String?
    let buildKinds: [String: MobileMacCompatRemoteRequirement]?
    // Legacy fields are accepted so older policy fixtures and a staged server
    // rollout remain readable. New payloads always use buildKinds.
    let stableMinVersion: String?
    let nightly: MobileMacCompatRemoteNightly?
}
