/// One wire-format iOS tier from the remote Mac compatibility list.
struct MobileMacCompatRemoteEntry: Decodable {
    let minIOSVersion: String
    let maxIOSVersion: String?
    /// Nil means no compatible stable Mac release exists for this tier yet.
    let stableMinVersion: String?
    let nightly: MobileMacCompatRemoteNightly?
}
