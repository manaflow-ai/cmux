/// One wire-format iOS tier from the remote Mac compatibility list.
struct MobileMacCompatRemoteEntry: Decodable {
    let minIOSVersion: String
    let maxIOSVersion: String?
    let stableMinVersion: String
    let nightly: MobileMacCompatRemoteNightly?
}
