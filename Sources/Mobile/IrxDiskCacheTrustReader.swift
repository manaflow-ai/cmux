import CmuxIrxTransport
import Foundation

/// Synchronous trust-snapshot reader used by irx admission. It performs no
/// actor hop or network access and reads the activation-selected cache path.
enum IrxDiskCacheTrustReader {
    static func read(stateDirectory: URL) -> IrxTrustSnapshot? {
        IrxDiskCache<IrxTrustSnapshot>(
            fileURL: stateDirectory.appendingPathComponent("trust.json")
        ).load()
    }
}
