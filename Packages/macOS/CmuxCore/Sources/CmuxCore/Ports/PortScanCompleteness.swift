/// Whether a port scan can authoritatively report absence.
public enum PortScanCompleteness: Sendable, Equatable {
    /// The scan observed every tracked key, so missing ports count toward removal.
    case complete

    /// The scan failed or returned a partial process snapshot, so only positive observations are authoritative.
    case incomplete
}
