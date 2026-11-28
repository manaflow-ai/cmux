import CMUXMobileCore
import Foundation
import Sentry
import Testing
@testable import CmuxSentryReporting

struct TerminalWorkSentryContextTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    @Test(arguments: [
        ("Fatal App Hang Fully Blocked", "AppHang"),
        ("Fatal App Hang Non Fully Blocked", "AppHang"),
        ("WatchdogTermination", "watchdog_termination"),
        ("MXHangDiagnostic", "mx_hang_diagnostic")
    ])
    func sdkHangCategoriesReceiveExplicitEvidence(type: String, mechanism: String) {
        let event = Event(level: .error)
        let exception = Exception(value: "Hang diagnostic", type: type)
        exception.mechanism = Mechanism(type: mechanism)
        event.exceptions = [exception]
        TerminalWorkSentryContext().apply(to: event)
        #expect(event.tags?["terminal.evidence"] == "unavailable")
    }

    @Test(arguments: [TerminalWorkDiagnostic.Phase.layout, .resizePublication, .ptyResizeRequest])
    func nestedPhaseIsAttributedAtCaptureEvenIfItLaterCompletes(phase: TerminalWorkDiagnostic.Phase) {
        let outer = UUID(), inner = UUID()
        let event = hang(at: 3)
        event.breadcrumbs = [
            crumb(id: outer, phase: .geometryPublication, transition: .restore, at: 1),
            crumb(id: inner, phase: phase, at: 2),
            crumb(id: inner, phase: phase, finished: true, at: 4)
        ]
        _ = SentryEventScrubber().scrub(event)
        #expect(event.tags?["terminal.phase"] == phase.rawValue)
        #expect(event.tags?["terminal.transition"] == "restore")
        #expect(event.tags?["terminal.evidence"] == "unfinished_at_capture")
        #expect(event.context?["cmux.terminal_work"]?["surface_count"] as? Int == 24)
        #expect(event.context?["cmux.terminal_work"]?["elapsed_ms_at_capture"] as? Double == 1_000)
    }

    @Test func completedAndBackgroundWorkCannotBeBlamedForAMainThreadHang() {
        let done = UUID()
        let event = hang(at: 5)
        event.breadcrumbs = [
            crumb(id: done, phase: .layout, at: 1),
            crumb(id: done, phase: .layout, finished: true, at: 2),
            crumb(id: UUID(), phase: .renderGridReplay, main: false, at: 3)
        ]
        TerminalWorkSentryContext().apply(to: event)
        #expect(event.tags?["terminal.phase"] == "unknown")
        #expect(event.tags?["terminal.evidence"] == "no_active_main_phase")
        #expect(event.context?["cmux.terminal_work"]?["unfinished_worker_phases"] as? [String] == ["renderGridReplay"])
    }

    @Test func completingOneSurfaceCannotEraseAnotherSurfacesPhase() {
        let first = UUID(), second = UUID()
        let event = hang(at: 5)
        event.breadcrumbs = [
            crumb(id: first, phase: .resizePublication, at: 1),
            crumb(id: second, phase: .resizePublication, at: 2),
            crumb(id: first, phase: .resizePublication, finished: true, at: 3)
        ]
        TerminalWorkSentryContext().apply(to: event)
        #expect(event.tags?["terminal.phase"] == "resizePublication")
        #expect(event.context?["cmux.terminal_work"]?["unfinished_phase_count"] as? Int == 1)
    }

    @Test func missingEvidenceAndMissingCaptureTimeStayUnknown() {
        let event = hang(at: 5)
        TerminalWorkSentryContext().apply(to: event)
        #expect(event.tags?["terminal.evidence"] == "unavailable")
        event.timestamp = nil
        event.breadcrumbs = [crumb(id: UUID(), phase: .layout, at: 1)]
        TerminalWorkSentryContext().apply(to: event)
        #expect(event.tags?["terminal.evidence"] == "unavailable")
    }

    @Test func phaseBreadcrumbUsesProducerTimeAndNoUserIdentity() throws {
        let work = TerminalWorkDiagnostic(
            operationID: UUID(), phase: .resizePublication,
            context: .init(transition: .resize, population: .window, workspaceCount: 3, surfaceCount: 24),
            onMainThread: true
        )
        let value = DiagnosticEvent(code: .terminalWorkStarted, tNanos: 1_000_000_000, terminalWork: work)
        let crumb = try #require(TerminalWorkSentryBreadcrumb().make(
            value, role: "macHost", wallTime: origin.addingTimeInterval(10), uptime: 10_000_000_000
        ))
        #expect(crumb.timestamp == origin.addingTimeInterval(1))
        #expect(Set(crumb.data?.keys.map { $0 } ?? []) == [
            "schema", "operation", "phase", "transition", "population", "main_thread", "role", "state",
            "workspace_count", "surface_count"
        ])
    }

    @Test func persistedWatchdogTimelinePreservesThePreviousProcessesActivePhase() {
        let event = PersistedWatchdogEvent(level: .fatal)
        event.timestamp = origin.addingTimeInterval(5)
        event.exceptions = [Exception(value: "Watchdog", type: "WatchdogTermination")]
        event.breadcrumbs = []
        let operation = UUID()
        event.persistedTimeline = [
            crumb(id: operation, phase: .geometryPublication, transition: .resize, at: 1).serialize(),
            crumb(id: operation, phase: .geometryPublication, finished: true, at: 8).serialize()
        ]
        TerminalWorkSentryContext().apply(to: event)
        #expect(event.tags?["terminal.phase"] == "geometryPublication")
        #expect(event.tags?["terminal.transition"] == "resize")
        #expect(event.tags?["terminal.evidence"] == "unfinished_at_capture")
    }

    private func hang(at seconds: Double) -> Event {
        let event = Event(level: .error)
        event.timestamp = origin.addingTimeInterval(seconds)
        event.exceptions = [Exception(value: "App hanging", type: "App Hanging")]
        return event
    }

    private func crumb(
        id: UUID,
        phase: TerminalWorkDiagnostic.Phase,
        transition: TerminalWorkContext.Transition = .unknown,
        main: Bool = true,
        finished: Bool = false,
        at seconds: Double
    ) -> Breadcrumb {
        let event = DiagnosticEvent(
            code: finished ? .terminalWorkFinished : .terminalWorkStarted,
            tNanos: UInt64(seconds * 1_000_000_000),
            terminalWork: .init(
                operationID: id, phase: phase,
                context: .init(transition: transition, population: .window, workspaceCount: 3, surfaceCount: 24),
                onMainThread: main
            )
        )
        return TerminalWorkSentryBreadcrumb().make(event, role: "macHost", wallTime: origin, uptime: 0)!
    }
}
