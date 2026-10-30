public import Testing
import AppKit
import CmuxNextTestGUIHost
import CmuxNextWakeups
import Foundation

/// Runs each test of a suite as the active app, or skips it with the reason when the run did not ask for a GUI.
///
/// Under `swift test` the process is no app: CmuxNextTestGUIHost (linked into the test bundle) dispatches NSApp's
/// events in every run, and in a run that asks for a GUI (`CMUX_CI_CONSOLE_SESSION=1`, set by the fleet worker on
/// every gui-session-v1 step, or `CMUX_TEST_REQUIRE_GUI=1`) it finishes launching as a regular app. It does not
/// activate: an activate at bundle load did not hold until a test ran (pump probe bcb9ab15), while an activate inside
/// the test did (activation probes 0ba1d205, 9a183366). So this trait activates before each test and waits for
/// AppKit's `didBecomeActiveNotification`, event-driven, with a bound only so a host that never grants it fails the
/// test instead of hanging the run. Without the opt-in the test is skipped (`Issue` free), so a person's own
/// `swift test` keeps their focus.
///
/// Each activation logs one `cmux-test-gui:` line: whether the process was already active before the call, and
/// which app took activation away if the process resigns during the test (`didResignActiveNotification`, with the
/// frontmost app at that moment): the record of why a single activation does not last.
public nonisolated struct GUIAppTrait: SuiteTrait, TestTrait, TestScoping {
    /// How long AppKit may take to make the process active before the test fails (the window server answers in
    /// milliseconds; a loaded host is given more).
    static let activationBound: Duration = .seconds(10)

    public init() {}

    public var isRecursive: Bool { true }

    /// One scope per test function; never for the suite itself.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase != nil ? nil : self
    }

    @concurrent public func provideScope(for test: Test, testCase: Test.Case?,
                                         performing function: @concurrent @Sendable () async throws -> Void) async throws {
        guard Self.runAsksForGUI else {
            try Test.cancel("needs an active app: set CMUX_CI_CONSOLE_SESSION=1 (fleet gui-session-v1 steps) or CMUX_TEST_REQUIRE_GUI=1")
        }
        let name = test.name
        let watch = await MainActor.run { ActivationWatch(test: name) }
        // The wait ends on AppKit's notice; the bound is the repo's race helper (R-timer), only so a host that never
        // grants activation fails the test instead of hanging the run.
        let became = (try? await Deadline(Self.activationBound).run("cmux-test-gui.activate") { await watch.activate() }) ?? false
        if !became { await MainActor.run { watch.log("never became active within \(Self.activationBound)") } }
        guard became else {
            await MainActor.run { watch.stop() }
            Issue.record("the test process did not become the active app within \(Self.activationBound) (\(await MainActor.run { watch.summary }))")
            return
        }
        do {
            try await function()
        } catch {
            await MainActor.run { watch.stop() }
            throw error
        }
        await MainActor.run { watch.stop() }
    }

    /// The run asked for a GUI: the fleet's gui-session-v1 steps, or a person who opts in.
    static var runAsksForGUI: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CMUX_CI_CONSOLE_SESSION"] == "1" || environment["CMUX_TEST_REQUIRE_GUI"] == "1"
    }
}

extension Trait where Self == GUIAppTrait {
    /// Runs each test of the suite as the active app; skips it with the reason when the run asks for no GUI.
    public static var guiApp: Self { GUIAppTrait() }
}

/// One test's activation: asks AppKit to activate, waits for its notice, and records a resign while the test runs.
@MainActor
final class ActivationWatch {
    private let test: String
    private var becameObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var waiting: CheckedContinuation<Bool, Never>?
    private var wasActive = false
    private var resigned: [String] = []

    init(test: String) { self.test = test }

    var summary: String {
        "test=\(test) wasActive=\(wasActive) launched=\(cmux_next_test_gui_host_launched()) active=\(NSApp.isActive) "
            + "frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") resignedTo=\(resigned)"
    }

    /// True once the process is the active app: at once when it already is, else when AppKit posts
    /// `didBecomeActiveNotification`. The caller bounds the wait (`Deadline`); a cancelled wait answers false.
    func activate() async -> Bool {
        wasActive = NSApp.isActive
        let center = NotificationCenter.default
        resignObserver = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteResign() }
        }
        if wasActive {
            log("already active")
            return true
        }
        // A cancelled wait (the caller's Deadline passed) resumes with false, so no continuation is left behind.
        let became: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                becameObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(true) }
                }
                NSApp.activate(ignoringOtherApps: true)
                if NSApp.isActive || Task.isCancelled { finish(NSApp.isActive) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(false) }
        }
        if became { log("became active") }
        return became
    }

    private func finish(_ value: Bool) {
        guard let waiting else { return }
        self.waiting = nil
        if let becameObserver { NotificationCenter.default.removeObserver(becameObserver) }
        becameObserver = nil
        waiting.resume(returning: value)
    }

    private func noteResign() {
        let to = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        resigned.append(to)
        log("resigned active; frontmost now \(to)")
    }

    func stop() {
        finish(false)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    func log(_ event: String) {
        print("cmux-test-gui: \(event): \(summary)")
    }
}
