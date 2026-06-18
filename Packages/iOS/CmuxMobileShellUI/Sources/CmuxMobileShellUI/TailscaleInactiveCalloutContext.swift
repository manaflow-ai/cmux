import Foundation

/// The surface hosting a ``TailscaleInactiveCallout``; selects the
/// explanation line. The raw value feeds the callout's analytics event.
enum TailscaleInactiveCalloutContext: String {
    case pairing
    case disconnected
}
