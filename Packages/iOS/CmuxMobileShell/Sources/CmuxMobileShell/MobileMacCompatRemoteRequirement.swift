/// One wire-format Mac compatibility requirement for an iOS build kind.
struct MobileMacCompatRemoteRequirement: Decodable {
    let stableMinVersion: String
    let nightly: MobileMacCompatRemoteNightly?
}
