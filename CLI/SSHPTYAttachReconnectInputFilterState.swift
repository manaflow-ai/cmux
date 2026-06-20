struct SSHPTYAttachReconnectInputFilterState: Sendable {
    let isFiltering: Bool
    let pending: [UInt8]
}
