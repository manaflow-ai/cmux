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
        /// `macScreen.shareWithoutAsking`, and how often the guide wrote it.
        var consent = false
        var remembers = 0

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
            setup.consented = { [weak self] in self?.consent ?? false }
            setup.rememberConsent = { [weak self] in
                self?.remembers += 1
                self?.consent = true
            }
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

    /// "Screen sharing + computer use" double prompt (Lawrence, 2026-11-17): macOS's own Screen
    /// Recording prompt and our Check Again sheet were up at once. While macOS's prompt has the
    /// person, no sheet of ours is presented; a grant made there skips Check Again entirely.
    @Test func noSheetOfOursWhileMacOSsPromptIsUp() async throws {
        let fixture = Fixture(permissions: (false, true), answers: ["allow"])
        var setup = fixture.setup()
        let gate = AnswerGate()
        setup.requestScreen = {
            fixture.screenRequests += 1
            _ = await gate.answer() // macOS's prompt is up until the gate opens
        }
        let task = Task { @MainActor in try await setup.proceed(after: "continue", present: fixture.present) }

        await gate.waitForEntry()
        #expect(fixture.presented == ["cmux.dialog.screenSharing.setup.screen"])
        fixture.permissions.screen = true // the person allowed it in macOS's prompt
        gate.cancel()

        #expect(try await task.value)
        #expect(fixture.screenRequests == 1)
        #expect(fixture.enables == 1)
        #expect(fixture.presented == ["cmux.dialog.screenSharing.setup.screen"])
    }

    /// Denied in macOS's prompt: Check Again comes only after macOS's prompt is gone.
    @Test func checkAgainComesOnlyAfterMacOSsPromptIsDone() async throws {
        let fixture = Fixture(permissions: (false, true), answers: ["allow", "cancel"])
        var setup = fixture.setup()
        var promptOpen = false
        var sheetsWhilePromptOpen = 0
        setup.requestScreen = {
            promptOpen = true
            fixture.screenRequests += 1
            await Task.yield()
            promptOpen = false
        }
        let present: (CmuxDialogSpec) async -> String = { spec in
            if promptOpen { sheetsWhilePromptOpen += 1 }
            return fixture.present(spec)
        }

        let shared = try await setup.proceed(after: "continue", present: present)
        #expect(!shared)
        #expect(sheetsWhilePromptOpen == 0)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.screen",
            "cmux.dialog.screenSharing.setup.screenCheck",
        ])
    }

    @Test(arguments: [true, false])
    func losingScreenRecordingDuringControlCheckReturnsToScreenGuide(controlGranted: Bool) async throws {
        let fixture = Fixture(permissions: (true, false), answers: ["allow", "check", "cancel"])
        fixture.afterAnswer = { identifier, answer in
            if identifier.hasSuffix(".controlCheck"), answer == "check" {
                fixture.permissions = (false, controlGranted)
            }
        }

        let shared = try await fixture.setup().proceed(after: "continue", present: fixture.present)

        #expect(!shared)
        #expect(fixture.enables == 0)
        #expect(fixture.controlRequests == 1)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.control",
            "cmux.dialog.screenSharing.setup.controlCheck",
            "cmux.dialog.screenSharing.setup.screen",
        ])
    }

    @Test func restoringScreenRecordingAfterControlCheckCanFinish() async throws {
        let fixture = Fixture(permissions: (true, false), answers: ["allow", "check", "allow", "check"])
        fixture.afterAnswer = { identifier, answer in
            guard answer == "check" else { return }
            if identifier.hasSuffix(".controlCheck") {
                fixture.permissions = (false, true)
            } else if identifier.hasSuffix(".screenCheck") {
                fixture.permissions.screen = true
            }
        }

        let shared = try await fixture.setup().proceed(after: "continue", present: fixture.present)

        #expect(shared)
        #expect(fixture.enables == 1)
        #expect(fixture.screenRequests == 1 && fixture.controlRequests == 1)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.control",
            "cmux.dialog.screenSharing.setup.controlCheck",
            "cmux.dialog.screenSharing.setup.screen",
            "cmux.dialog.screenSharing.setup.screenCheck",
        ])
    }

    @Test func continuingWithoutControlRechecksScreenAndPreservesThatChoice() async throws {
        let fixture = Fixture(permissions: (true, false), answers: ["view", "allow", "check"])
        fixture.afterAnswer = { identifier, answer in
            if answer == "view" {
                fixture.permissions.screen = false
            } else if identifier.hasSuffix(".screenCheck"), answer == "check" {
                fixture.permissions.screen = true
            }
        }

        let shared = try await fixture.setup().proceed(after: "continue", present: fixture.present)

        #expect(shared)
        #expect(fixture.enables == 1)
        #expect(fixture.screenRequests == 1 && fixture.controlRequests == 0)
        #expect(!fixture.permissions.control)
        #expect(fixture.presented == [
            "cmux.dialog.screenSharing.setup.control",
            "cmux.dialog.screenSharing.setup.screen",
            "cmux.dialog.screenSharing.setup.screenCheck",
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

    @Test(arguments: ["cli", "mcp", "script", "remote", "page", "socket", "app", "agent", "terminal", "nested"])
    func automationPresentsOverviewEvenWithReadyPermissions(caller: String) async throws {
        _ = NSApplication.shared
        let fixture = Fixture(permissions: (true, true), answers: [])
        let setup = fixture.setup()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            CmuxDialogCenter.shared.dismissAll()
            window.close()
        }
        window.orderFrontRegardless()

        var invocation = ActionInvocation(origin: ActionOrigin(rawValue: caller) ?? .user)
        invocation.viaControlSocket = caller == "socket"
        invocation.callerApp = caller == "app" ? "example-app" : nil
        invocation.callerAgentSession = caller == "agent" ? "example-session" : nil
        invocation.callerTerminal = caller == "terminal" ? "example-terminal" : nil
        let scope = ActionRunScope(origin: caller == "nested" ? .script : invocation.origin, allowsViewChange: false)
        let effect = ActionRunScope.carrying(scope) {
            setup.begin(in: window, invocation: invocation)
        }
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

    @Test func nativeShareWithReadyPermissionsEnablesWithoutOverview() async throws {
        _ = NSApplication.shared
        let fixture = Fixture(permissions: (true, true), answers: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var presented: [String] = []
        let observer = CmuxDialogCenter.shared.observe { event in
            guard case .opened(let record) = event else { return }
            presented.append(record.spec.identifier ?? "")
            _ = CmuxDialogCenter.shared.press(record.id, button: "cancel")
        }
        defer {
            CmuxDialogCenter.shared.stopObserving(observer)
            CmuxDialogCenter.shared.dismissAll()
            window.close()
        }

        let effect = fixture.setup().begin(in: window)
        guard case .appliedResult(let result) = effect.kind else {
            Issue.record("Share should return an applied result effect")
            return
        }
        let outcome = await result()
        guard case .success(let fields) = outcome else {
            Issue.record("Share with ready permissions should succeed")
            return
        }
        #expect(fields["shared"] == .bool(true))
        #expect(fixture.enables == 1)
        #expect(presented.isEmpty)
        #expect(fixture.screenRequests == 0 && fixture.controlRequests == 0)
        #expect(CmuxDialogCenter.shared.records.isEmpty)
    }

    @Test(arguments: ["screen", "control", "both", "revoked"])
    func nativeSharePreservesMissingPermissionConsent(missing: String) async throws {
        _ = NSApplication.shared
        let fixture = Fixture(permissions: (true, true), answers: [])
        var setup = fixture.setup()
        var reads = 0
        setup.refresh = {
            reads += 1
            if missing == "revoked" { return (reads == 1, true) }
            return (missing == "control", missing == "screen")
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var presented: [String] = []
        let observer = CmuxDialogCenter.shared.observe { event in
            guard case .opened(let record) = event else { return }
            presented.append(record.spec.identifier ?? "")
            _ = CmuxDialogCenter.shared.press(record.id, button: "cancel")
        }
        defer {
            CmuxDialogCenter.shared.stopObserving(observer)
            CmuxDialogCenter.shared.dismissAll()
            window.close()
        }
        let effect = setup.begin(in: window)
        guard case .appliedResult(let result) = effect.kind else {
            Issue.record("Share should return an applied result effect")
            return
        }
        let outcome = await result()
        guard case .success(let fields) = outcome else {
            Issue.record("Cancelling permission setup should return shared:false")
            return
        }
        #expect(fields["shared"] == .bool(false))
        #expect(fixture.enables == 0)
        #expect(presented == ["cmux.dialog.screenSharing.setup.\(missing == "revoked" ? "screen" : "overview")"])
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

    /// Leo, 2026-11-19: "The permissions, just removing them, getting rid of the ceremony". After the
    /// person's one yes, the owner's CLI or agent turns sharing on with no sheet at all (no window needed).
    @Test func ownerRequestAfterTheOneYesSharesWithNoSheet() async throws {
        let fixture = Fixture(permissions: (true, false), answers: [])
        fixture.consent = true
        let setup = fixture.setup()

        let shared = try await setup.ownerRequest(in: nil)
        #expect(shared)
        #expect(fixture.enables == 1)
        #expect(fixture.presented.isEmpty)
        #expect(fixture.remembers == 0)
    }

    /// Without the person's yes an owner request never turns sharing on by itself: it needs the guide.
    @Test func ownerRequestWithoutTheYesNeverSharesOnItsOwn() async throws {
        let fixture = Fixture(permissions: (true, true), answers: [])
        let setup = fixture.setup()

        let shared = try await setup.ownerRequest(in: nil)
        #expect(!shared)
        #expect(fixture.enables == 0)
    }

    /// The yes does not stand in for macOS's Screen Recording grant.
    @Test func ownerRequestAfterTheYesStillNeedsScreenRecording() async throws {
        let fixture = Fixture(permissions: (false, true), answers: [])
        fixture.consent = true
        let setup = fixture.setup()

        let shared = try await setup.ownerRequest(in: nil)
        #expect(!shared)
        #expect(fixture.enables == 0)
    }

    /// Finishing the guide is the one yes, kept; declining it keeps nothing.
    @Test func finishingTheGuideRemembersTheYesOnceAndDecliningDoesNot() async throws {
        let declined = Fixture(permissions: (true, true), answers: [])
        let notShared = try await declined.setup().proceed(after: "cancel", present: declined.present)
        #expect(!notShared)
        #expect(declined.remembers == 0)

        let fixture = Fixture(permissions: (true, true), answers: [])
        let setup = fixture.setup()
        #expect(try await setup.proceed(after: "continue", present: fixture.present))
        #expect(try await setup.proceed(after: "continue", present: fixture.present))
        #expect(fixture.remembers == 1)
        #expect(fixture.consent)
    }

    /// A native Share click with both grants ready shows no sheet, so it never records the standing
    /// yes the overview sheet names (review of #47312).
    @Test func aSheetlessNativeShareKeepsNoStandingYes() async throws {
        let fixture = Fixture(permissions: (true, true), answers: [])
        let setup = fixture.setup()

        #expect(try await setup.proceed(after: "continue", remembersYes: false, present: fixture.present))
        #expect(fixture.enables == 1)
        #expect(fixture.presented.isEmpty)
        #expect(fixture.remembers == 0)
        #expect(!fixture.consent)
    }

    /// The overview sheet, the only one whose answer records the yes, says what the yes allows.
    @Test func theOverviewNamesTheStandingYes() {
        let lines = CmuxRemoteSharingSetup.spec(.overview).lines.joined(separator: " ")
        #expect(lines.contains("without asking"))
    }

    /// The standing yes, as `CmuxRemoteShareConsent.holds` decides it (review of #47312, P1 and P2): a `true`
    /// an agent wrote into cmux-next.json alone approves nothing; this Mac's record of the answered sheet
    /// or a device MDM force does; a team policy is not the person's yes; off is never a yes.
    @Test func onlyTheAnsweredSheetOrDeviceMDMMakeTheStandingYes() {
        #expect(!CmuxRemoteShareConsent.holds(settingOn: true, managed: nil, recorded: false))
        #expect(CmuxRemoteShareConsent.holds(settingOn: true, managed: nil, recorded: true))
        #expect(CmuxRemoteShareConsent.holds(settingOn: true, managed: .device, recorded: false))
        #expect(!CmuxRemoteShareConsent.holds(settingOn: true, managed: .team("t"), recorded: false))
        #expect(!CmuxRemoteShareConsent.holds(settingOn: false, managed: .device, recorded: true))
    }

    /// Turning the setting off drops the record, so a later file-only `true` needs the sheet again
    /// instead of reviving the old yes (review of #47312, P1).
    @Test func turningTheSettingOffForgetsTheYes() throws {
        let suite = "ss-share-consent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date(), forKey: CmuxRemoteShareConsent.recordKey)

        CmuxRemoteShareConsent.forgetUnlessOn(settingOn: true, defaults: defaults)
        #expect(defaults.object(forKey: CmuxRemoteShareConsent.recordKey) is Date)
        CmuxRemoteShareConsent.forgetUnlessOn(settingOn: false, defaults: defaults)
        #expect(defaults.object(forKey: CmuxRemoteShareConsent.recordKey) == nil)
        #expect(!CmuxRemoteShareConsent.holds(settingOn: true, managed: nil,
                                               recorded: defaults.object(forKey: CmuxRemoteShareConsent.recordKey) is Date))
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
