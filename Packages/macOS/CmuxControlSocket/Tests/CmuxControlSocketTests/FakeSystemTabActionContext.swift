import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSystemTabActionContext: ControlCommandContext {
    var resolution: ControlTabActionResolution = .tabManagerUnavailable
    var receivedTitle: String?
    var receivedTitleSource: String?

    func controlTabAction(
        routing: ControlRoutingSelectors,
        actionKey: String?,
        title: String?,
        titleSource: String?,
        rawURL: String?,
        surfaceID: UUID?,
        requestedFocus: Bool,
        moveParams: [String: JSONValue]
    ) -> ControlTabActionResolution {
        receivedTitle = title
        receivedTitleSource = titleSource
        return resolution
    }
}
