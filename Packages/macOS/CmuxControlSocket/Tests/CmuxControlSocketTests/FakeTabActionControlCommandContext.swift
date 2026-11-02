import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeTabActionControlCommandContext: ControlCommandContext {
    var resolution: ControlTabActionResolution = .tabManagerUnavailable
    private(set) var actionKey: String?
    private(set) var badge: String?
    private(set) var surfaceID: UUID?
    private(set) var force = false

    func controlTabAction(
        routing: ControlRoutingSelectors,
        actionKey: String?,
        title: String?,
        badge: String?,
        rawURL: String?,
        surfaceID: UUID?,
        requestedFocus: Bool,
        force: Bool,
        moveParams: [String: JSONValue]
    ) -> ControlTabActionResolution {
        self.actionKey = actionKey
        self.badge = badge
        self.surfaceID = surfaceID
        self.force = force
        return resolution
    }
}
