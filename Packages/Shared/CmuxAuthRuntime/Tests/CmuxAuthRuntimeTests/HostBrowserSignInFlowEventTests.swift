import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The countable sign-in steps the flow reports to its host (product
/// analytics). A window close is reported only when the user's close ends the
/// attempt, never for a replaced attempt, a sign-out or a callback race.
@MainActor
@Suite(.serialized) struct HostBrowserSignInFlowEventTests {
    private static let first = HostBrowserSignInAttempt(1)
    private static let second = HostBrowserSignInAttempt(2)
    private static let user = CMUXAuthUser(id: "u1", primaryEmail: "a@b.com", displayName: "A")

    private func recordEvents(_ harness: HostBrowserSignInFlowHarness) -> EventRecorder {
        let recorder = EventRecorder()
        harness.flow.onEvent = { recorder.events.append($0) }
        return recorder
    }

    @Test func windowCallbackReportsCallbackThenCompletion() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        let attempt = harness.flow.beginSignIn()
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        session.deliver(harness.callbackURL(state: harness.callbackState(session)))

        #expect(await attempt.value)
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .callbackReceived(.signInWindow, attempt: Self.first),
            .signInCompleted(attempt: Self.first),
        ])
    }

    @Test func userCloseReportsWindowClosedAndALateDefaultBrowserCallbackStillCompletes() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        let attempt = harness.flow.beginSignIn()
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        let state = harness.callbackState(session)
        session.deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))
        #expect(await attempt.value == false)
        #expect(recorder.events == [.attemptStarted(Self.first), .windowClosedByUser(Self.first)])
        #expect(harness.flow.lastFailure == nil)

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: state), delivery: .external))
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .windowClosedByUser(Self.first),
            .callbackReceived(.external, attempt: Self.first),
            .signInCompleted(attempt: Self.first),
        ])
    }

    @Test func replacedAttemptAndSignOutReportNoWindowClose() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let retry = harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)
        // ASWebAuthenticationSession reports an app-side cancel as a user
        // cancel; the replaced attempt already ended, so it must not count.
        harness.factory.sessions[0].deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))

        await harness.flow.signOut()
        #expect(await retry.value == false)
        harness.factory.sessions[1].deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))

        #expect(recorder.events == [.attemptStarted(Self.first), .attemptStarted(Self.second)])
    }

    @Test func replacedAttemptsOldTabCallbackNamesTheAttemptThatIssuedIt() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let oldTabState = harness.callbackState(harness.factory.sessions[0])
        let retry = harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: oldTabState), delivery: .external))
        #expect(await retry.value)
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .attemptStarted(Self.second),
            .callbackReceived(.external, attempt: Self.first),
            .signInCompleted(attempt: Self.first),
        ])
    }

    @Test func oldTabCallbackThatFailsValidationNamesTheAttemptThatIssuedIt() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)
        await harness.client.setCurrentUserError(AuthError.networkError)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let oldTabState = harness.callbackState(harness.factory.sessions[0])
        harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)

        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: oldTabState), delivery: .external) == false)
        #expect(harness.flow.lastFailure != nil)
        // The retry's window stays open: the failed old tab did not end it.
        #expect(harness.flow.isSigningIn)
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .attemptStarted(Self.second),
            .callbackReceived(.external, attempt: Self.first),
            .callbackFailed(attempt: Self.first),
        ])
        await harness.flow.signOut()
    }

    @Test func refusedCallbacksNameOnlyTheAttemptThatIssuedTheirState() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        harness.flow.beginSignIn()
        await harness.waitForSession()
        let oldTabState = harness.callbackState(harness.factory.sessions[0])
        harness.flow.beginSignIn()
        await harness.waitForSession(count: 2)

        // A malformed old-tab callback, then one carrying a state no attempt issued.
        let malformed = URL(string: "cmux-dev://auth-callback?cmux_auth_state=\(oldTabState)")!
        #expect(await harness.flow.handleCallbackURL(malformed, delivery: .external) == false)
        #expect(await harness.flow.handleCallbackURL(harness.callbackURL(state: "never-issued"), delivery: .external) == false)

        #expect(harness.flow.isSigningIn)
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .attemptStarted(Self.second),
            .callbackRefused(attempt: Self.first),
            .callbackRefused(attempt: nil),
        ])
        await harness.flow.signOut()
    }

    @Test func statelessEmbeddedCallbackNamesNoAttempt() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        #expect(await harness.flow.handleCallbackURL(harness.fallbackCallbackURL(), delivery: .trustedEmbeddedBrowser))
        #expect(recorder.events == [.callbackReceived(.embeddedBrowser, attempt: nil), .signInCompleted(attempt: nil)])
    }

    @Test func closeReportedWhileAnExternalCallbackValidatesIsNotAWindowClose() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)
        await harness.client.closeUserGate()
        let attempt = Task { await harness.flow.signIn(timeout: 60) }
        await harness.waitForSession()
        let session = harness.factory.sessions[0]
        let state = harness.callbackState(session)

        let callback = Task { await harness.flow.handleCallbackURL(harness.callbackURL(state: state)) }
        await harness.waitForPendingUserRequest()
        session.deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))
        await harness.client.openUserGate()

        #expect(await callback.value)
        #expect(await attempt.value)
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .callbackReceived(.external, attempt: Self.first),
            .signInCompleted(attempt: Self.first),
        ])
    }

    @Test func rejectedWindowCallbackReportsTheCallbackButNoCompletion() async {
        let harness = HostBrowserSignInFlowHarness(user: Self.user)
        let recorder = recordEvents(harness)

        let attempt = harness.flow.beginSignIn()
        await harness.waitForSession()
        harness.factory.sessions[0].deliver(harness.callbackURL(state: "not-the-issued-state"))

        #expect(await attempt.value == false)
        #expect(harness.flow.lastFailure == .invalidCallback)
        #expect(recorder.events == [
            .attemptStarted(Self.first),
            .callbackReceived(.signInWindow, attempt: Self.first),
            .callbackFailed(attempt: Self.first),
        ])
    }
}

@MainActor
private final class EventRecorder {
    var events: [HostBrowserSignInEvent] = []
}
