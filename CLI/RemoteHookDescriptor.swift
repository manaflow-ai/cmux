struct RemoteHookDescriptor: Codable {
    let name: String
    let aliases: [String]
    let binaryName: String
    let configDirectory: String
    let installWhenConfigMissing: Bool
    let snapshotPaths: [String]
    let recursivePaths: [String]

    enum CodingKeys: String, CodingKey {
        case name, aliases
        case binaryName = "binary_name"
        case configDirectory = "config_directory"
        case installWhenConfigMissing = "install_when_config_missing"
        case snapshotPaths = "snapshot_paths"
        case recursivePaths = "recursive_paths"
    }
}
