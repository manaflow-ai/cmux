import CmuxInstallAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// cx-wb5.64: the Mac app's Cloud install principal. It registers kind mac
/// with the mac grant at sign-in, mints install tokens without the Stack
/// session afterwards, and revokes the install at sign-out. A development
/// build keeps its key and records in 0600 files (no Keychain prompt per
/// rebuild); a signed build keeps the key in the Secure Enclave.
/// One install.register call, as the fake owner saw it.
private struct Registration: Sendable, Equatable {
    var kind: String?
    var platform: String?
    var opClasses: [String]?
    var keyX: String?
}

private actor FakeOwner: InstallAuthTransport {
    var registered: [Registration] = []
    var revoked: [String] = []
    var mints = 0
    var sessionCalls = 0

    nonisolated func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        try await handle(path, json, bearer)
    }

    private func reply(_ object: [String: Any], _ status: Int = 200) throws -> (status: Int, body: Data) {
        (status, try JSONSerialization.data(withJSONObject: object))
    }

    private func handle(_ path: String, _ json: Data, _ bearer: String?) throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        switch path {
        case "/v1/ops":
            guard bearer == "session" else { return try reply(["code": "auth.unauthenticated"], 401) }
            sessionCalls += 1
            let params = body["params"] as? [String: Any] ?? [:]
            switch body["op"] as? String {
            case "user.ensure": return try reply(["ok": true, "value": ["id": "user_1", "stack_user_id": "stack_1"]])
            case "install.revoke":
                revoked.append(params["install"] as? String ?? "")
                return try reply(["ok": true, "value": ["id": params["install"] ?? ""]])
            default:
                registered.append(Registration(kind: params["kind"] as? String, platform: params["platform"] as? String,
                                               opClasses: params["op_classes"] as? [String],
                                               keyX: (params["public_jwk"] as? [String: String])?["x"]))
                return try reply(["ok": true, "value": ["id": "inst_\(registered.count)"]])
            }
        case "/v1/auth/challenge":
            let install = body["install"] as? String ?? ""
            guard !revoked.contains(install) else { return try reply(["code": "auth.forbidden"], 403) }
            return try reply(["nonce": String(repeating: "a", count: 32), "message_prefix": "cmux-auth-v1\ndevelopment\n\(install)\n"])
        case "/v1/auth/token":
            mints += 1
            let payload = try JSONSerialization.data(withJSONObject: ["iss": "https://cmux-api/development", "n": mints])
            let token = "eyJhbGciOiJFUzI1NiJ9.\(payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")).c2ln"
            return try reply(["access_token": token, "expires_at": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000])
        default:
            return try reply([:], 404)
        }
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-install-\(UUID().uuidString)", isDirectory: true)
    return url
}

private func identity(_ owner: FakeOwner, _ directory: URL) -> MacInstallIdentity {
    MacInstallIdentity(store: .files(directory: directory), transport: owner, deviceName: "cmux-test-mac", clientVersion: "1.0.0")
}

@Suite struct MacInstallIdentityTests {
    @Test func signInRegistersAMacInstallWithTheMacGrantAndMintsAToken() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        let mac = identity(owner, directory)
        try await mac.signedIn(stackUser: "stack_1", session: { "session" })
        let registered = await owner.registered
        #expect(registered.count == 1)
        #expect(registered.first?.kind == "mac")
        #expect(registered.first?.platform == "macos")
        #expect(registered.first?.opClasses == ["read", "mutate-own", "mutate-shared", "cloud-link"])
        #expect(await owner.mints == 1)
        #expect(try await mac.installToken().hasPrefix("eyJ"))
    }

    @Test func aRestartedAppMintsWithoutTheSessionAndWithoutRegisteringAgain() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        try await identity(owner, directory).signedIn(stackUser: "stack_1", session: { "session" })
        let sessionCalls = await owner.sessionCalls
        let restarted = identity(owner, directory)
        await restarted.restore(stackUser: "stack_1", session: nil)
        _ = try await restarted.installToken()
        #expect(await owner.registered.count == 1)
        #expect(await owner.sessionCalls == sessionCalls)
        #expect(await owner.mints == 2)
    }

    @Test func signOutRevokesTheInstallAndForgetsItsKeyAndRecord() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        let mac = identity(owner, directory)
        try await mac.signedIn(stackUser: "stack_1", session: { "session" })
        await mac.signOut()
        #expect(await owner.revoked == ["inst_1"])
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await mac.installToken() }
        // The next sign-in registers a new install with a new key.
        try await mac.signedIn(stackUser: "stack_1", session: { "session" })
        let keys = await owner.registered.map(\.keyX)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    @Test func aDevelopmentStoreKeepsItsFilesOwnerOnly() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        try await identity(owner, directory).signedIn(stackUser: "stack_1", session: { "session" })
        let mode = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(directory) == 0o700)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in files { #expect(mode(file) == 0o600, "\(file.lastPathComponent)") }
    }
}
