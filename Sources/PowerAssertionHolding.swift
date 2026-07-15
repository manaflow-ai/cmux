import Foundation

@MainActor
protocol PowerAssertionHolding: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}
