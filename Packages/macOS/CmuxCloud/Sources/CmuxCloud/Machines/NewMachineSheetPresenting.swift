import AppKit

/// Presents machine provisioning from synchronous AppKit command entrypoints.
@MainActor
public protocol NewMachineSheetPresenting: AnyObject {
    /// Publishes the reservation at acceptance; the returned receipt must not drive placement.
    func presentNewMachineFetchingPlan(
        preferredWindow: NSWindow?,
        onReservation: @escaping @MainActor (UUID) -> Void
    ) async -> UUID?
}
