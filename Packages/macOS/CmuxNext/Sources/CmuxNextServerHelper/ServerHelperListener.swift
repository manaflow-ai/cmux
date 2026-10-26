public import Foundation
import Security

/// The helper's listener: accepts a connection only from the app bundle that
/// carries the helper, signed by the helper's own team. The team comes from
/// the helper's own signature, so no team id is hard-coded and an unsigned or
/// ad hoc helper accepts nobody. It owns the `NSXPCListener` and is used from
/// the helper's main code only; XPC's queue calls ``ServerHelperConnectionGate``.
public final nonisolated class ServerHelperListener {
    private let listener: NSXPCListener
    /// Strong here: `NSXPCListener.delegate` is weak.
    private let gate: ServerHelperConnectionGate

    public init(machServiceName: String, appBundleID: String, service: ServerHelperService = ServerHelperService()) {
        listener = NSXPCListener(machServiceName: machServiceName)
        let requirement = ServerHelperConstants().clientRequirement(teamID: ServerHelperListener.ownTeamIdentifier(), appBundleID: appBundleID)
        gate = ServerHelperConnectionGate(service: service, requirement: requirement)
        listener.delegate = gate
    }

    /// False when the helper cannot serve anyone (no team in its signature).
    public var acceptsClients: Bool { gate.acceptsClients }

    public func resume() { listener.resume() }

    /// The team identifier of the running process, or nil when it is unsigned or ad hoc.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The listener's delegate. XPC calls it on its own queue for each new
/// connection, so it holds only immutable Sendable values.
final nonisolated class ServerHelperConnectionGate: NSObject, NSXPCListenerDelegate, Sendable {
    private let service: ServerHelperService
    private let requirement: String?

    init(service: ServerHelperService, requirement: String?) {
        self.service = service
        self.requirement = requirement
    }

    var acceptsClients: Bool { requirement != nil }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: (any ServerHelperProtocol).self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
