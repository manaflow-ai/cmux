public import Foundation
import Security

/// The helper's listener: accepts a connection only from a process signed by
/// the helper's own team, with a cmux bundle identifier. The requirement comes
/// from the helper's own signature, so no team id is hard-coded and an
/// unsigned or ad hoc helper accepts nobody.
public final nonisolated class ServerHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let service: ServerHelperService
    private let requirement: String?

    public init(service: ServerHelperService = ServerHelperService()) {
        listener = NSXPCListener(machServiceName: ServerHelperConstants.machServiceName)
        self.service = service
        requirement = ServerHelperListener.clientRequirement(teamID: ServerHelperListener.ownTeamIdentifier())
        super.init()
        listener.delegate = self
    }

    public func resume() { listener.resume() }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ServerHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    /// The code-signing requirement a client must meet, or nil without a team.
    public static func clientRequirement(teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty, teamID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (identifier \"com.cmuxterm.app\" or identifier \"com.cmuxterm.app.debug\" or identifier \"com.cmuxterm.app.nightly\")"
    }

    /// The team identifier of the running helper, or nil when it is unsigned or ad hoc.
    static func ownTeamIdentifier() -> String? {
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
