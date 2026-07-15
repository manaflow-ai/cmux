import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakePerformanceControlCommandContext: ControlCommandContext {
    private(set) var calls: [String] = []

    func controlPerformanceMetricsRead() -> JSONValue? {
        calls.append("read")
        return .object(["enabled": .bool(true)])
    }

    func controlPerformanceMetricsReset() -> JSONValue? {
        calls.append("reset")
        return .object(["enabled": .bool(true), "reset": .bool(true)])
    }

    func controlPerformanceMetricsStop() -> JSONValue? {
        calls.append("stop")
        return .object(["enabled": .bool(false)])
    }
}

@MainActor
@Suite("ControlCommandCoordinator performance metrics")
struct ControlCommandCoordinatorPerformanceTests {
    @Test func routesReleaseSafeReadResetAndStop() {
        let context = FakePerformanceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        #expect(coordinator.handle(request("performance.metrics.read")) == .ok(.object([
            "enabled": .bool(true),
        ])))
        #expect(coordinator.handle(request("performance.metrics.reset")) == .ok(.object([
            "enabled": .bool(true),
            "reset": .bool(true),
        ])))
        #expect(coordinator.handle(request("performance.metrics.stop")) == .ok(.object([
            "enabled": .bool(false),
        ])))
        #expect(context.calls == ["read", "reset", "stop"])
    }

    @Test func unrelatedMethodFallsThrough() {
        let coordinator = ControlCommandCoordinator(context: FakePerformanceControlCommandContext())
        #expect(coordinator.handle(request("performance.unowned")) == nil)
    }

    private func request(_ method: String) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: [:])
    }
}
