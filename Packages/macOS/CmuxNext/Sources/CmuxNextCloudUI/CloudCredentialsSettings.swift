public import CmuxNextCloud
public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > Cloud > Cloud Credentials (webviews `CloudCredentialsCard.tsx`,
/// https://github.com/manaflow-ai/cmux/issues/48427, exploratory): `cmux.settings.cloudCredentials.state`
/// answers the selected team's cmux OIDC issuer as the Cloud API's `GET /v1/cloud/oidc/info` gives it, read
/// with the person's own session: `{available: false}` signed out, `{available: true, info}`, or
/// `{available: true, error}` with the API's code (the page words it). Read when the card opens and on Try
/// Again; nothing polls, and no token passes through here (only Cloud machines hold them).
@MainActor
public final class CloudCredentialsSettings: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.cloudCredentials.state"

    private let signedIn: @MainActor () -> Bool
    private let read: @MainActor () async throws -> Data

    /// `read` is ``CloudOwnerAPIClient/cloudCredentialsInfo()`` for the selected team.
    public init(signedIn: @escaping @MainActor () -> Bool, read: @escaping @MainActor () async throws -> Data) {
        self.signedIn = signedIn
        self.read = read
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard signedIn() else { return ["available": false] }
        do {
            return ["available": true, "info": try JSONValue.parse(try await read())]
        } catch let CloudAPIError.http(status, code, _, _, _) {
            return ["available": true, "error": .string(code ?? "http.\(status)")]
        } catch {
            return ["available": true, "error": "unreachable"]
        }
    }
}
