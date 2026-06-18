#if DEBUG
import Foundation

extension String {
    /// The string's unicode scalars as a comma-separated list of uppercase
    /// four-digit hex values, used by debug key-routing probes to journal
    /// exact event characters.
    public var unicodeScalarHexList: String {
        unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }
}
#endif
