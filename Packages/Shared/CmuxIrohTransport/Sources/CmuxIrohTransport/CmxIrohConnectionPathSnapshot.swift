/// The minimum package-internal data copied from one Iroh FFI path snapshot.
struct CmxIrohConnectionPathSnapshot: Equatable, Sendable {
    let isSelected: Bool
    let remoteAddress: String
    let isIP: Bool
    let isRelay: Bool

    init(isSelected: Bool, remoteAddress: String, isIP: Bool, isRelay: Bool) {
        self.isSelected = isSelected
        self.remoteAddress = remoteAddress
        self.isIP = isIP
        self.isRelay = isRelay
    }
}
