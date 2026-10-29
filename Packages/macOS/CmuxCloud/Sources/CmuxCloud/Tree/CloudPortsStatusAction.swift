import Foundation

/// The action exposed by an actionable Ports status callout.
public enum CloudPortsStatusAction: Equatable, Sendable {
    case none
    case refresh
    case setupVPN
    case openMachine
    case openShell
}
