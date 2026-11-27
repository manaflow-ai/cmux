@testable import CmuxNextPopups
import Foundation

/// Opens a ``FakeWebAuthSurface`` per request, or none when ``opens`` is
/// false. ``duringOpen`` runs inside `open` before it returns: a tab that
/// closes or reaches its callback while it opens.
final class FakeWebAuthOpener: WebAuthSessionOpening {
    var opens = true
    var duringOpen: ((any WebAuthSessionRequest, WebAuthSessionBroker) -> Void)?
    private(set) var opened: [UUID] = []
    private(set) var surfaces: [UUID: FakeWebAuthSurface] = [:]

    func open(_ request: any WebAuthSessionRequest, broker: WebAuthSessionBroker) -> (any WebAuthSessionSurface)? {
        opened.append(request.id)
        duringOpen?(request, broker)
        guard opens else { return nil }
        let surface = FakeWebAuthSurface()
        surfaces[request.id] = surface
        return surface
    }
}
