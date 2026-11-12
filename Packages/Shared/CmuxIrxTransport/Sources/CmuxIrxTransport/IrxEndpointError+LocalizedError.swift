public import Foundation

extension IrxEndpointError: LocalizedError {
    /// Preserves the safe native relay diagnosis in Foundation error presentation.
    public var errorDescription: String? {
        guard case .bindFailed(let description) = self else { return nil }
        return description
    }
}
