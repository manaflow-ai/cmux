#if canImport(IrohLib)
import IrohLib

extension CmxIrohConnectionPathSnapshot {
    init(_ snapshot: PathSnapshot) {
        self.init(
            isSelected: snapshot.isSelected,
            remoteAddress: snapshot.remoteAddr,
            isIP: snapshot.isIp,
            isRelay: snapshot.isRelay
        )
    }
}
#endif
