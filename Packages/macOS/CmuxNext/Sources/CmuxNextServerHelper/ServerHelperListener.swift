public import Foundation
import Security

/// The helper's listener: accepts a connection only from the app bundle that
/// carries the helper, signed by the helper's own team. The team comes from
/// the helper's own signature, so no team id is hard-coded and an unsigned or
/// ad hoc helper accepts nobody.
public final nonisolated class ServerHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let service: ServerHelperService
    private let requirement: String?

    public init(machServiceName: String, appBundleID: String, service: ServerHelperService = ServerHelperService()) {
        listener = NSXPCListener(machServiceName: machServiceName)
        self.service = service
        requirement = ServerHelperConstants.clientRequirement(teamID: ServerHelperListener.ownTeamIdentifier(), appBundleID: appBundleID)
        super.init()
        listener.delegate = self
    }

    /// False when the helper cannot serve anyone (no team in its signature).
    public var acceptsClients: Bool { requirement != nil }

    public func resume() { listener.resume() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ServerHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

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
