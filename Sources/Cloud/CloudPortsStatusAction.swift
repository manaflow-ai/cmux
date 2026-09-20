import Foundation

/// The action exposed by an actionable Ports status callout.
enum CloudPortsStatusAction: Equatable {
    case none
    case refresh
    case openMachine
    case openShell
}
