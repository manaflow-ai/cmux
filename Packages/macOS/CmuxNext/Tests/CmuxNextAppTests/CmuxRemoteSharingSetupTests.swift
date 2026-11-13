import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextActions
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// The first Share This Mac action is a person-approved guide, not a settings toggle. These tests
/// keep the TCC and Device Hub edges behind the same closures the guide uses in production.
@MainActor @Suite(.serialized, .closesItsWindows)
struct CmuxRemoteSharingSetupTests {
    @MainActor final class Fixture {
        var permissions: (screen: Bool, control: Bool)
        var answers: [String]
        var presented: [String] = []
        var afterAnswer: (@MainActor (String, String) -> Void)?
        var screenRequests = 0
        var controlRequests = 0
        var enables = 0

        init(permissions: (Bool, Bool), answers: [String]) {
            self.permissions = permissions
            self.answers = answers
        }

        func setup() -> CmuxRemoteSharingSetup {
            let share = MacScreenShareHost()
            let host = MacScreenHubHost(share: share)
            var setup = CmuxRemoteSharingSetup(host: host)
            setup.refresh = { [weak self] in
                guard let self else { return (false, false) }
                return self.permissions
            }
            setup.requestScreen = { [weak self] in self?.screenRequests += 1 }
            setup.requestControl = { [weak self] in self?.controlRequests += 1 }
            setup.enable = { [weak self] in self?.enables += 1 }
            return setup
        }

        func present(_ spec: CmuxDialogSpec) -> String {
            presented.append(spec.identifier ?? "")
            let answer = answers.isEmpty ? "cancel" : answers.removeFirst()
            afterAnswer?(spec.identifier ?? "", answer)
            return answer
        }
    }

    @MainActor final class AnswerGate {
        private var continuation: CheckedContinuation<String, Never>?
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false

        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enteredContinuation = continuation
            }
        }

        func answer() async -> String {
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                self.continuation = continuation
                entered = true
                enteredContinuation?.resume()
                enteredContinuation = nil
            }
        }

        func cancel() {
            continuation?.resume(returning: "cancel")
            continuation = nil
        }
    }

    @Test func cancellationNeverEnablesSharing() async throws {
        let fixture = Fixture(permissions: (false, false), answers: ["cancel"])
        let setup = fixture.setup()

        let shared = try await setup.proceed(after: "cancel", present: fixture.present)
        #expect(!shared)
        #expect(fixture.enables == 0)
        #expect(fixture.screenRequests == 0)
    }

    @Test func screenRecordingCannotBeSkippedByCheck() async throws {
        let fixture = Fixture(permissions: (false, true), answers: ["check", "cancel"])
        let setup = fixture.setup()

        let shared = try await setup.proceed(after: "continue", present: fixture.present)
        #expect(!shared)
        #expect(fixture.enables == 0)
        #expect(fixture.screenRequests == 0)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.screen",
            "cmux.dialog.screenSharing.setup.screen",
        ])
    }

    @Test func optionalAccessibilityAdvancesOnlyOnExplicitView() async throws {
        let fixture = Fixture(permissions: (true, false), answers: ["check", "view"])
        let setup = fixture.setup()

        let shared = try await setup.proceed(after: "continue", present: fixture.present)
        #expect(shared)
        #expect(fixture.enables == 1)
        #expect(fixture.controlRequests == 0)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.control",
            "cmux.dialog.screenSharing.setup.control",
        ])
    }

    @Test func firstUseRefreshesBothPermissionsBeforeEnabling() async throws {
        let fixture = Fixture(permissions: (false, false), answers: ["allow", "check", "allow", "check"])
        fixture.afterAnswer = { identifier, answer in
            guard answer == "check" else { return }
            if identifier.hasSuffix(".screenCheck") {
                fixture.permissions.screen = true
            } else if identifier.hasSuffix(".controlCheck") {
                fixture.permissions.control = true
            }
        }
        let setup = fixture.setup()

        let shared = try await setup.proceed(after: "continue", present: fixture.present)
        #expect(shared)
        #expect(fixture.screenRequests == 1)
        #expect(fixture.controlRequests == 1)
        #expect(fixture.enables == 1)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.screen",
            "cmux.dialog.screenSharing.setup.screenCheck",
            "cmux.dialog.screenSharing.setup.control",
            "cmux.dialog.screenSharing.setup.controlCheck",
        ])
    }

    @Test func cancellationInsidePermissionSheetNeverEnablesSharing() async throws {
        let fixture = Fixture(permissions: (false, true), answers: ["cancel"])
        let setup = fixture.setup()

        let shared = try await setup.proceed(after: "continue", present: fixture.present)
        #expect(!shared)
        #expect(fixture.enables == 0)
        #expect(fixture.presented == ["cmux.dialog.screenSharing.setup.screen"])
    }

    @Test func taskCancellationWhilePermissionSheetIsOpenNeverEnablesSharing() async throws {
        let fixture = Fixture(permissions: (false, true), answers: [])
        let setup = fixture.setup()
        let gate = AnswerGate()
        let task = Task { @MainActor in
            try await setup.proceed(after: "continue", present: { spec in
                fixture.presented.append(spec.identifier ?? "")
                return await gate.answer()
            })
        }

        await gate.waitForEntry()
        task.cancel()
        gate.cancel()
        let shared = try await task.value
        #expect(!shared)
        #expect(fixture.enables == 0)
        #expect(fixture.presented == ["cmux.dialog.screenSharing.setup.screen"])
    }

    @Test func beginPresentsOverviewSynchronouslyAndCancelReturnsFalse() async throws {
        _ = NSApplication.shared
        let fixture = Fixture(permissions: (false, false), answers: [])
        let setup = fixture.setup()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            CmuxDialogCenter.shared.dismissAll()
            window.close()
        }
        window.orderFrontRegardless()

        let effect = setup.begin(in: window)
        let overview = try #require(CmuxDialogCenter.shared.records.first {
            $0.spec.identifier == "cmux.dialog.screenSharing.setup.overview"
        })
        #expect(CmuxDialogCenter.shared.press(overview.id, button: "cancel"))

        guard case .appliedResult(let result) = effect.kind else {
            Issue.record("begin should return an applied result effect")
            return
        }
        let outcome = await result()
        guard case .success(let fields) = outcome else {
            Issue.record("cancelling the overview should return a successful shared:false result")
            return
        }
        #expect(fields["shared"] == .bool(false))
        #expect(fixture.enables == 0)
        #expect(CmuxDialogCenter.shared.records.isEmpty)
    }

    @Test func readyPermissionsEnableWithoutPrompts() async throws {
        let fixture = Fixture(permissions: (true, true), answers: [])
        let setup = fixture.setup()

        let shared = try await setup.proceed(after: "continue", present: fixture.present)
        #expect(shared)
        #expect(fixture.enables == 1)
        #expect(fixture.presented.isEmpty)
        #expect(fixture.screenRequests == 0 && fixture.controlRequests == 0)
    }

    @Test func eachGuideStepHasAStableIdentifierAndCancel() {
        for step in CmuxRemoteSharingSetup.Step.allCases {
            let spec = CmuxRemoteSharingSetup.spec(step)
            #expect(spec.identifier == "cmux.dialog.screenSharing.setup.\(step.rawValue)")
            #expect(spec.cancelButton?.id == "cancel")
            #expect(!spec.title.isEmpty && !spec.lines.isEmpty)
        }
    }
}
