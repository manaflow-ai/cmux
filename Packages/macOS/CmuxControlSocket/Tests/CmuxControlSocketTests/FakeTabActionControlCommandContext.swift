import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeTabActionControlCommandContext: ControlCommandContext {
    var resolution: ControlTabActionResolution = .tabManagerUnavailable
    private(set) var actionKey: String?
    private(set) var surfaceID: UUID?

    func controlTabAction(
        routing: ControlRoutingSelectors,
        actionKey: String?,
        title: String?,
        rawURL: String?,
        surfaceID: UUID?,
        requestedFocus: Bool,
        moveParams: [String: JSONValue]
    ) -> ControlTabActionResolution {
        self.actionKey = actionKey
        self.surfaceID = surfaceID
        return resolution
    }
}
