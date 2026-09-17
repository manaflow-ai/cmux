/// Platform boundary for installing and observing the optional system VPN.
@MainActor
public protocol CloudSystemVPNManaging: AnyObject {
    var phase: CloudSystemVPNPhase { get }
    var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)? { get set }
    func refresh(scope: String) async throws
    func installAndStart(configuration: String, scope: String) async throws
    func stop(removeConfiguration: Bool) async throws
}
