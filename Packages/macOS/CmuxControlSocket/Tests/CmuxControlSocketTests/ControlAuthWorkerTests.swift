import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``AuthStatusReading`` for driving ``ControlAuthWorker`` without
/// the app target or a live auth coordinator.
private actor FakeAuthStatusReading: AuthStatusReading {
    var snapshot: ControlAuthStatus?
    var signInURLValue: String?
    var beginSignInResult = false

    private(set) var awaitBootstrappedCount = 0
    private(set) var signOutCount = 0
    private(set) var lastBeginSignInTimeout: TimeInterval?

    init(snapshot: ControlAuthStatus? = nil) {
        self.snapshot = snapshot
    }

    func awaitBootstrapped() async { awaitBootstrappedCount += 1 }
    func statusSnapshot() async -> ControlAuthStatus? { snapshot }
    func signInURL() async -> String? { signInURLValue }
    func beginSignIn(timeoutSeconds: TimeInterval) async -> Bool {
        lastBeginSignInTimeout = timeoutSeconds
        return beginSignInResult
    }
    func signOut() async { signOutCount += 1 }
}

private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
    ControlRequest(id: .string("1"), method: method, params: params)
}

@Suite struct ControlAuthWorkerTests {
    @Test func returnsNilForNonAuthMethod() async {
        let worker = ControlAuthWorker(reading: FakeAuthStatusReading())
        #expect(await worker.handle(request("system.ping")) == nil)
    }

    @Test func statusAwaitsBootstrapAndReportsNotSignedInWithoutCoordinator() async {
        let reading = FakeAuthStatusReading(snapshot: nil)
        let worker = ControlAuthWorker(reading: reading)
        let result = await worker.handle(request("auth.status"))
        #expect(await reading.awaitBootstrappedCount == 1)
        #expect(result == .ok(.object([
            "signed_in": .bool(false),
            "is_restoring_session": .bool(false),
            "is_loading": .bool(false),
            "timed_out": .bool(false),
        ])))
    }

    @Test func statusEncodesFullSnapshotWithUserTeamsAndSelection() async {
        let snapshot = ControlAuthStatus(
            signedIn: true,
            isRestoringSession: false,
            isLoading: true,
            user: ControlAuthUser(id: "u1", email: "a@b.co", displayName: "Ada"),
            selectedTeamID: "t1",
            teams: [
                ControlAuthTeam(id: "t1", displayName: "Team One", slug: "one"),
                ControlAuthTeam(id: "t2", displayName: "Team Two", slug: nil),
            ]
        )
        let worker = ControlAuthWorker(reading: FakeAuthStatusReading(snapshot: snapshot))
        let result = await worker.handle(request("auth.status"))
        #expect(result == .ok(.object([
            "signed_in": .bool(true),
            "is_restoring_session": .bool(false),
            "is_loading": .bool(true),
            "timed_out": .bool(false),
            "user": .object([
                "id": .string("u1"),
                "email": .string("a@b.co"),
                "display_name": .string("Ada"),
            ]),
            "selected_team_id": .string("t1"),
            "teams": .array([
                .object(["id": .string("t1"), "display_name": .string("Team One"), "slug": .string("one")]),
                .object(["id": .string("t2"), "display_name": .string("Team Two")]),
            ]),
        ])))
    }

    @Test func statusOmitsUserEmailDisplayNameAndTeamsWhenAbsent() async {
        let snapshot = ControlAuthStatus(
            signedIn: true,
            isRestoringSession: true,
            isLoading: false,
            user: ControlAuthUser(id: "u1", email: nil, displayName: nil),
            selectedTeamID: nil,
            teams: []
        )
        let worker = ControlAuthWorker(reading: FakeAuthStatusReading(snapshot: snapshot))
        let result = await worker.handle(request("auth.status"))
        #expect(result == .ok(.object([
            "signed_in": .bool(true),
            "is_restoring_session": .bool(true),
            "is_loading": .bool(false),
            "timed_out": .bool(false),
            "user": .object(["id": .string("u1")]),
        ])))
    }

    @Test func signInURLOmitsKeyWhenNil() async {
        let worker = ControlAuthWorker(reading: FakeAuthStatusReading())
        #expect(await worker.handle(request("auth.sign_in_url")) == .ok(.object([:])))
    }

    @Test func signInURLEmitsURLWhenPresent() async {
        let reading = FakeAuthStatusReading()
        await reading.setSignInURL("https://example.test/signin")
        let worker = ControlAuthWorker(reading: reading)
        #expect(await worker.handle(request("auth.sign_in_url"))
            == .ok(.object(["url": .string("https://example.test/signin")])))
    }

    @Test func beginSignInDefaultsTimeoutTo300AndReportsTimedOutOnFailure() async {
        let reading = FakeAuthStatusReading(snapshot: ControlAuthStatus(
            signedIn: false, isRestoringSession: false, isLoading: false,
            user: nil, selectedTeamID: nil, teams: []
        ))
        await reading.setBeginSignInResult(false)
        let worker = ControlAuthWorker(reading: reading)
        let result = await worker.handle(request("auth.begin_sign_in"))
        #expect(await reading.lastBeginSignInTimeout == 300)
        #expect(result == .ok(.object([
            "signed_in": .bool(false),
            "is_restoring_session": .bool(false),
            "is_loading": .bool(false),
            "timed_out": .bool(true),
        ])))
    }

    @Test func beginSignInUsesProvidedIntTimeoutAndClearsTimedOutOnSuccess() async {
        let reading = FakeAuthStatusReading(snapshot: ControlAuthStatus(
            signedIn: true, isRestoringSession: false, isLoading: false,
            user: nil, selectedTeamID: nil, teams: []
        ))
        await reading.setBeginSignInResult(true)
        let worker = ControlAuthWorker(reading: reading)
        let result = await worker.handle(request("auth.begin_sign_in", ["timeout_seconds": .int(42)]))
        #expect(await reading.lastBeginSignInTimeout == 42)
        #expect(result == .ok(.object([
            "signed_in": .bool(true),
            "is_restoring_session": .bool(false),
            "is_loading": .bool(false),
            "timed_out": .bool(false),
        ])))
    }

    @Test func signOutDrivesSeamAndReportsNotTimedOut() async {
        let reading = FakeAuthStatusReading(snapshot: ControlAuthStatus(
            signedIn: false, isRestoringSession: false, isLoading: false,
            user: nil, selectedTeamID: nil, teams: []
        ))
        let worker = ControlAuthWorker(reading: reading)
        let result = await worker.handle(request("auth.sign_out"))
        #expect(await reading.signOutCount == 1)
        #expect(result == .ok(.object([
            "signed_in": .bool(false),
            "is_restoring_session": .bool(false),
            "is_loading": .bool(false),
            "timed_out": .bool(false),
        ])))
    }
}

extension FakeAuthStatusReading {
    func setSignInURL(_ value: String?) { signInURLValue = value }
    func setBeginSignInResult(_ value: Bool) { beginSignInResult = value }
}
