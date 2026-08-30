import CmuxIrxTransport
import Foundation

/// Synchronous trust-snapshot reader used by irx admission. It performs no
/// actor hop or network access and reads the activation-selected cache path.
struct IrxDiskCacheTrustReader: Sendable {
    private let cache: IrxDiskCache<IrxTrustSnapshot>

    init(stateDirectory: URL) {
        cache = IrxDiskCache(
            fileURL: stateDirectory.appendingPathComponent("trust.json")
        )
    }

    /// Reads the activation-selected trust snapshot without crossing an actor.
    nonisolated func read() -> IrxTrustSnapshot? {
        cache.load()
    }
}
