/// The wire-format nightly requirement nested in a remote iOS tier.
struct MobileMacCompatRemoteNightly: Decodable {
    let minBaseVersion: String
    let minBuild: String
}
