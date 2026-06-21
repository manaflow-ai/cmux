import AppKit
import Testing
@testable import CmuxWindowing

@Suite("AppLaunchBootstrap")
@MainActor
struct AppLaunchBootstrapTests {
    private func makeBootstrap(
        bundleIdentifier: String? = "com.cmuxterm.app.test",
        bundleURL: URL = URL(fileURLWithPath: "/tmp/cmux-launch-bootstrap-test.app"),
        currentPid: Int32 = 4242,
        runningApplications: @escaping @MainActor (String) -> [NSRunningApplication] = { _ in [] },
        activateCurrent: @escaping @MainActor () -> Void = {},
        startupBreadcrumb: @escaping @MainActor (String, [String: String]) -> Void = { _, _ in }
    ) -> AppLaunchBootstrap {
        AppLaunchBootstrap(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            currentPid: currentPid,
            runningApplications: runningApplications,
            activateCurrent: activateCurrent,
            startupBreadcrumb: startupBreadcrumb
        )
    }

    /// Thread-safe counter the `@Sendable` register closure can increment.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    /// Captures the deferred work handed to the scheduler.
    private final class WorkBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _work: (@Sendable () -> Void)?
        func store(_ work: @escaping @Sendable () -> Void) { lock.lock(); _work = work; lock.unlock() }
        var work: (@Sendable () -> Void)? { lock.lock(); defer { lock.unlock() }; return _work }
    }

    @Test("LaunchServices registration is deferred to the scheduler, not run inline")
    func registrationDefersRegisterWork() {
        let workBox = WorkBox()
        let registerCounter = CallCounter()

        makeBootstrap(
            bundleURL: URL(fileURLWithPath: "/tmp/../tmp/cmux-launch-services-test.app")
        ).scheduleLaunchServicesRegistration(
            scheduler: { work in workBox.store(work) },
            register: { _ in
                registerCounter.increment()
                return noErr
            },
            breadcrumb: { _, _ in }
        )

        #expect(registerCounter.count == 0)
        #expect(workBox.work != nil)

        workBox.work?()
        #expect(registerCounter.count == 1)
    }

    /// Thread-safe sink so the `@Sendable` breadcrumb closure can record events.
    private final class BreadcrumbRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _completeStatus: Int?
        func record(_ message: String, _ data: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            _events.append(message)
            if message == "launchservices.register.complete" {
                _completeStatus = data["status"] as? Int
            }
        }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
        var completeStatus: Int? { lock.lock(); defer { lock.unlock() }; return _completeStatus }
    }

    @Test("registration emits schedule then complete breadcrumbs with status")
    func registrationEmitsBreadcrumbs() {
        let recorder = BreadcrumbRecorder()

        makeBootstrap().scheduleLaunchServicesRegistration(
            scheduler: { work in work() },
            register: { _ in noErr },
            breadcrumb: { message, data in recorder.record(message, data) }
        )

        #expect(recorder.events == ["launchservices.register.schedule", "launchservices.register.complete"])
        #expect(recorder.completeStatus == Int(noErr))
    }

    @Test("single-instance enforcement skips with a breadcrumb when bundle id is missing")
    func enforceSkipsWithoutBundleId() {
        var skipReason: String?
        makeBootstrap(
            bundleIdentifier: nil,
            startupBreadcrumb: { event, fields in
                if event == "singleInstance.enforce.skip" { skipReason = fields["reason"] }
            }
        ).enforceSingleInstance()
        #expect(skipReason == "missingBundleId")
    }

    @Test("single-instance enforcement queries running apps and reports completion")
    func enforceQueriesRunningApps() {
        var queriedBundleId: String?
        var completeEvent: String?
        makeBootstrap(
            bundleIdentifier: "com.cmuxterm.app.test",
            runningApplications: { bundleId in
                queriedBundleId = bundleId
                return []
            },
            startupBreadcrumb: { event, _ in
                if event == "singleInstance.enforce.complete" { completeEvent = event }
            }
        ).enforceSingleInstance()
        #expect(queriedBundleId == "com.cmuxterm.app.test")
        #expect(completeEvent == "singleInstance.enforce.complete")
    }

    @Test("duplicate-launch observation returns nil and skips when bundle id is missing")
    func observeSkipsWithoutBundleId() {
        var skipReason: String?
        let token = makeBootstrap(
            bundleIdentifier: nil,
            startupBreadcrumb: { event, fields in
                if event == "singleInstance.observe.skip" { skipReason = fields["reason"] }
            }
        ).observeDuplicateLaunches()
        #expect(token == nil)
        #expect(skipReason == "missingBundleId")
    }

    @Test("duplicate-launch observation installs an observer token and breadcrumb")
    func observeInstallsObserver() {
        var installEvent: String?
        let bootstrap = makeBootstrap(
            startupBreadcrumb: { event, _ in
                if event == "singleInstance.observe.install" { installEvent = event }
            }
        )
        let token = bootstrap.observeDuplicateLaunches()
        #expect(token != nil)
        #expect(installEvent == "singleInstance.observe.install")
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
