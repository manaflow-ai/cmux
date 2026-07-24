import CmuxSimulator
@testable import CmuxSimulatorWorker

actor GatedAccessibilityExecutor: SimulatorAccessibilityExecuting {
    static let application = SimulatorApplicationInfo(
        bundleIdentifier: "com.example.fixture",
        processIdentifier: 123,
        name: "Fixture",
        version: nil,
        build: nil,
        minimumOSVersion: nil,
        isReactNative: false
    )

    private var foregroundContinuation: CheckedContinuation<Void, Never>?
    private var foregroundReadObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var foregroundReadCount = 0
    private var accessibilityContinuation: CheckedContinuation<Void, Never>?
    private var accessibilityReadObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var accessibilityReadCount = 0

    static let snapshot = SimulatorAccessibilitySnapshot(
        roots: [],
        display: SimulatorAccessibilityRequestSchedulingTests.display,
        nodeCount: 0
    )

    func attach(device _: SimulatorAccessibilityDevice) -> Bool { true }

    func detach() {}

    func foregroundApplication() async throws -> SimulatorApplicationInfo? {
        foregroundReadCount += 1
        let observers = foregroundReadObservers
        foregroundReadObservers.removeAll()
        for (count, observer) in observers where foregroundReadCount >= count {
            observer.resume()
        }
        await withCheckedContinuation { foregroundContinuation = $0 }
        return Self.application
    }

    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) async throws -> SimulatorAccessibilitySnapshot {
        accessibilityReadCount += 1
        let observers = accessibilityReadObservers
        accessibilityReadObservers.removeAll()
        for (count, observer) in observers where accessibilityReadCount >= count {
            observer.resume()
        }
        await withCheckedContinuation { accessibilityContinuation = $0 }
        return SimulatorAccessibilitySnapshot(
            roots: Self.snapshot.roots,
            display: display,
            nodeCount: Self.snapshot.nodeCount
        )
    }

    func waitForForegroundReadCount(_ count: Int) async {
        guard foregroundReadCount < count else { return }
        await withCheckedContinuation { foregroundReadObservers.append((count, $0)) }
    }

    func releaseForegroundRead() {
        foregroundContinuation?.resume()
        foregroundContinuation = nil
    }

    func waitForAccessibilityReadCount(_ count: Int) async {
        guard accessibilityReadCount < count else { return }
        await withCheckedContinuation { accessibilityReadObservers.append((count, $0)) }
    }

    func releaseAccessibilityRead() {
        accessibilityContinuation?.resume()
        accessibilityContinuation = nil
    }
}
