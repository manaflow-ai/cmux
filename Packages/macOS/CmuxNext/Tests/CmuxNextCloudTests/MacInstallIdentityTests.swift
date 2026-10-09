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
    /// While set, install.register waits until ``releaseRegister()``.
    private var holdRegister: CheckedContinuation<Void, Never>?
    private var holding = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func holdRegisters() { holding = true }
    func registerHeld() async {
        if holdRegister != nil { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }
    func releaseRegister() {
        holding = false
        holdRegister?.resume()
        holdRegister = nil
    }

    nonisolated func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        if path == "/v1/ops", body["op"] as? String == "install.register" { await waitIfHeld() }
        return try await handle(path, json, bearer)
    }

    private func waitIfHeld() async {
        guard holding else { return }
        await withCheckedContinuation { continuation in
            holdRegister = continuation
            for waiter in heldWaiters { waiter.resume() }
            heldWaiters = []
        }
    }

    private func reply(_ object: [String: Any], _ status: Int = 200) throws -> (status: Int, body: Data) {
        (status, try JSONSerialization.data(withJSONObject: object))
    }

    private func handle(_ path: String, _ json: Data, _ bearer: String?) throws -> (status: Int, body: Data) {
        let body = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        switch path {
        case "/v1/ops":
            // A session token names its Stack user: "session" is stack_1, "session-<user>" is <user>.
            guard let bearer, bearer.hasPrefix("session") else { return try reply(["code": "auth.unauthenticated"], 401) }
            let stackUser = bearer == "session" ? "stack_1" : String(bearer.dropFirst("session-".count))
            sessionCalls += 1
            let params = body["params"] as? [String: Any] ?? [:]
            switch body["op"] as? String {
            case "user.ensure": return try reply(["ok": true, "value": ["id": "user_\(stackUser)", "stack_user_id": stackUser]])
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
        try await restarted.signedIn(stackUser: "stack_1", session: { throw CancellationError() })
        #expect(await owner.registered.count == 1)
        #expect(await owner.sessionCalls == sessionCalls)
        #expect(await owner.mints == 2)
    }

    @Test func signOutRevokesTheInstallAndForgetsItsKeyAndRecord() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        let mac = identity(owner, directory)
        try await mac.signedIn(stackUser: "stack_1", session: { "session" })
        await mac.signOut(stackUser: "stack_1", session: { "session" })
        #expect(await owner.revoked == ["inst_1"])
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await mac.installToken() }
        // The session ends (the app's observer unbinds); the next sign-in
        // registers a new install with a new key.
        await mac.unbind()
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

@Suite struct MacInstallIdentityReviewTests {
    /// Release builds call the API Worker (cloud-api.cmux.dev), never the web
    /// origin; a development build may override it.
    @Test func installCallsGoToTheAPIWorker() {
        let release = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app", bundled: [:], process: [:], isDebugBuild: false)
        #expect(release.ownerAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": "https://evil.test"]).absoluteString == "https://cloud-api.cmux.dev")
        let staging = CloudConfiguration.resolve(bundleID: "test.dev", bundled: ["CMUX_VM_API_BASE_URL": "https://dev.test"], process: [:], isDebugBuild: true)
        #expect(staging.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cloud-api-staging.cmux.dev")
        #expect(staging.ownerAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": "http://127.0.0.1:8787"]).absoluteString == "http://127.0.0.1:8787")
    }

    @Test func aSignOutDuringRegistrationLeavesNothingThatCanMint() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        let mac = identity(owner, directory)
        await owner.holdRegisters()
        let signIn = Task { try await mac.signedIn(stackUser: "stack_1", session: { "session" }) }
        await owner.registerHeld()
        await mac.signOut(stackUser: "stack_1", session: { "session" })
        await owner.releaseRegister()
        _ = try? await signIn.value
        await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await mac.installToken() }
        // Nothing on disk lets a restarted app mint for that install.
        let restarted = identity(owner, directory)
        let mintsBefore = await owner.mints
        await #expect(throws: (any Error).self) {
            try await restarted.signedIn(stackUser: "stack_1", session: { throw CancellationError() })
        }
        #expect(await owner.mints == mintsBefore)
    }

    @Test func twoStackUsersEachKeepTheirOwnKey() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        let mac = identity(owner, directory)
        try await mac.signedIn(stackUser: "ada", session: { "session-ada" })
        try await mac.signedIn(stackUser: "bob", session: { "session-bob" })
        // Ada again, without a session: her key and record still mint.
        try await mac.signedIn(stackUser: "ada", session: { throw CancellationError() })
        let registered = await owner.registered
        #expect(registered.count == 2)
        #expect(registered[0].keyX != registered[1].keyX)
    }

    @Test func onlyADebugBuildWithoutATeamUsesTheFileStore() {
        let directory = temporaryDirectory()
        #expect(!MacInstallStore.forApp(directory: directory, service: "s", team: nil, isDebugBuild: true).usesSecureEnclave)
        #expect(MacInstallStore.forApp(directory: directory, service: "s", team: nil, isDebugBuild: false).usesSecureEnclave)
        #expect(MacInstallStore.forApp(directory: directory, service: "s", team: "ABCDE12345", isDebugBuild: true).usesSecureEnclave)
    }
}

@Suite struct MacInstallIdentitySignOutTests {
    /// A sign-out before this launch bound the user (the record and key come
    /// from an earlier launch) still revokes that install.
    @Test func aSignOutWithNothingBoundRevokesTheStoredInstall() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        try await identity(owner, directory).signedIn(stackUser: "stack_1", session: { "session" })
        let relaunched = identity(owner, directory)
        await relaunched.signOut(stackUser: "stack_1", session: { "session" })
        #expect(await owner.revoked == ["inst_1"])
    }

    /// Between this sign-out and the session's end, a late sign-in callback
    /// registers nothing.
    @Test func noRegistrationBetweenSignOutAndTheEndOfTheSession() async throws {
        let owner = FakeOwner(), directory = temporaryDirectory()
        let mac = identity(owner, directory)
        await mac.signOut(stackUser: "stack_1", session: { "session" })
        await #expect(throws: MacInstallIdentity.Failure.signedOut) {
            try await mac.signedIn(stackUser: "stack_1", session: { "session" })
        }
        #expect(await owner.registered.isEmpty)
        // The session ended (unbind); the next sign-in registers again.
        await mac.unbind()
        try await mac.signedIn(stackUser: "stack_1", session: { "session" })
        #expect(await owner.registered.count == 1)
    }
}
