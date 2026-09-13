import AppKit

/// Presents machine provisioning from synchronous AppKit command entrypoints.
@MainActor
protocol NewMachineSheetPresenting: AnyObject {
    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?) async -> UUID?
}
