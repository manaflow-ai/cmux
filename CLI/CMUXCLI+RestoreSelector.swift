extension CMUXCLI {
    /// The surface identity constraints parsed from `cmux restore` arguments.
    struct RestoreSelector {
        let surface: String?
        let usesCurrentSurface: Bool
        let kind: String?
        let checkpointID: String?
    }
}
