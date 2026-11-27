import IrohLib

/// The minimum package-internal data copied from one Iroh FFI path snapshot.
struct CmxIrohConnectionPathSnapshot: Equatable, Sendable {
    let isSelected: Bool
    let remoteAddress: String
    let isIP: Bool
    let isRelay: Bool

    init(_ snapshot: PathSnapshot) {
        isSelected = snapshot.isSelected
        remoteAddress = snapshot.remoteAddr
        isIP = snapshot.isIp
        isRelay = snapshot.isRelay
    }

    init(isSelected: Bool, remoteAddress: String, isIP: Bool, isRelay: Bool) {
        self.isSelected = isSelected
        self.remoteAddress = remoteAddress
        self.isIP = isIP
        self.isRelay = isRelay
    }
}
