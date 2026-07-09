import Foundation
import Testing
@testable import CmuxSettings

@MainActor
@Suite("AppIconAppearanceObserver")
struct AppIconAppearanceObserverTests {
    private final class ObservationToken: AppIconAppearanceObservation {
        private(set) var invalidateCallCount = 0
        func invalidate() { invalidateCallCount += 1 }
    }

    @MainActor
    private final class Harness {
        var isFinishedLaunching = false
        var isDark = false
        var startObservationCallCount = 0
        var currentAppearanceIsDarkCallCount = 0
        var imageRequests: [String] = []
        var didFinishLaunchingObserverCount = 0
        private(set) var didFinishLaunchingHandler: (() -> Void)?
        private(set) var appearanceHandler: (() -> Void)?
        let observation = ObservationToken()
        let launchObservation = ObservationToken()

        lazy var environment = AppIconAppearanceObserver.Environment(
            isApplicationFinishedLaunching: { [unowned self] in self.isFinishedLaunching },
            startEffectiveAppearanceObservation: { [unowned self] handler in
                self.startObservationCallCount += 1
                self.appearanceHandler = handler
                return self.observation
            },
            addDidFinishLaunchingObserver: { [unowned self] handler in
                self.didFinishLaunchingObserverCount += 1
                self.didFinishLaunchingHandler = handler
                return self.launchObservation
            },
            currentAppearanceIsDark: { [unowned self] in
                self.currentAppearanceIsDarkCallCount += 1
                return self.isDark
            },
            applyIconImage: { [unowned self] name in
                self.imageRequests.append(name)
                return true
            }
        )

        func fireDidFinishLaunching() { didFinishLaunchingHandler?() }
        func fireAppearanceChanged() { appearanceHandler?() }
    }

    @Test func startObservingDefersInitialApplyUntilLaunch() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        #expect(harness.didFinishLaunchingObserverCount == 1)
        #expect(harness.startObservationCallCount == 0)
        #expect(harness.imageRequests.isEmpty)

        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()
        #expect(harness.startObservationCallCount == 1)
        #expect(harness.imageRequests == ["AppIconLight"])
    }

    @Test func stopObservingCancelsDeferredLaunchApply() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()
        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        #expect(harness.startObservationCallCount == 0)
        #expect(harness.imageRequests.isEmpty)
        #expect(harness.launchObservation.invalidateCallCount == 1)
    }

    @Test func stopObservingInvalidatesActiveObservation() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()

        #expect(harness.startObservationCallCount == 1)
        #expect(harness.observation.invalidateCallCount == 1)
    }

    @Test func unchangedAppearanceDoesNotReapply() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.fireAppearanceChanged()

        #expect(harness.currentAppearanceIsDarkCallCount == 2)
        #expect(harness.imageRequests == ["AppIconLight"])
    }

    @Test func appearanceChangeAppliesNewIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.isDark = true
        harness.fireAppearanceChanged()

        #expect(harness.imageRequests == ["AppIconLight", "AppIconDark"])
    }
}
