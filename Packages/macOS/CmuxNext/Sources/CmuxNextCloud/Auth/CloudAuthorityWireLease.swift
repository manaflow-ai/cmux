package import Foundation
import CmuxInstallAuthCore

/// One original install's short-lived credential for one owner wire, never operation authority.
package struct CloudAuthorityWireLease: Sendable {
    package enum Owner: String, Sendable { case user, team }
    package enum Failure: Error, Equatable { case identity, expired, origin, frame, closed, handshake }
    let owner: Owner
    let user: String
    let team: String
    let install: String
    let token: String
    package let expiresAt: Date
    var stream: String { "\(owner.rawValue):\(owner == .user ? user : team)" }

    init(owner: Owner, context: NativeInstallContext, team: String, token: String, now: Date) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 16_384, parts.count == 3,
              let data = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              claims.iss == "https://cmux-api/" + context.environment, claims.aud == "api",
              claims.sub == context.user, claims.inst == context.install, claims.team == team,
              !claims.grant.isEmpty, claims.grant.utf8.count <= 128,
              claims.agt == nil, claims.vm == nil, claims.tvm == nil else { throw Failure.identity }
        guard claims.exp.isFinite, claims.exp > now.timeIntervalSince1970 else { throw Failure.expired }
        self.owner = owner; user = context.user; install = context.install; self.team = team; self.token = token
        expiresAt = min(Date(timeIntervalSince1970: claims.exp), now.addingTimeInterval(InstallAuthClient.maximumLifetime))
    }

    private struct Claims: Decodable {
        let iss: String; let aud: String; let sub: String; let inst: String; let team: String; let grant: String
        let exp: Double; let agt: String?; let vm: String?; let tvm: String?
    }
}
