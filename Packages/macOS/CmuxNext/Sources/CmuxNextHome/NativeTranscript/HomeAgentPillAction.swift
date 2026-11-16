import AppKit

/// The Objective-C target that runs a closure for an agent pill card's Start now button; the card keeps it alive.
@MainActor
final class HomeAgentPillAction: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
