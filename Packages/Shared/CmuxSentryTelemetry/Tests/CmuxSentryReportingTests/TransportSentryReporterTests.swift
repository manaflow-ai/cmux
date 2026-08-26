import CMUXMobileCore
import Foundation
import Sentry
import Testing
import os
@testable import CmuxSentryReporting

@Suite struct TransportSentryReporterTests {
    private static let second: UInt64 = 1_000_000_000

    /// Thread-safe recorder for the injected delivery seams.
    private final class Recorder: Sendable {
        struct LogLine: Sendable {
            let level: TransportSentryReporter.LogLevel
            let message: String
            let attributes: [String: String]
        }

        struct CapturedEvent: Sendable {
            let title: String
            let level: SentryLevel
            let fingerprint: [String]?
            let tags: [String: String]?
            let hasAttachment: Bool
            let attachmentFilename: String?
        }

        struct CapturedBreadcrumb: Sendable {
            let category: String
            let message: String?
            let level: SentryLevel
            let data: [String: String]
        }

        let breadcrumbs = OSAllocatedUnfairLock<[CapturedBreadcrumb]>(initialState: [])
        let events = OSAllocatedUnfairLock<[CapturedEvent]>(initialState: [])
        let logs = OSAllocatedUnfairLock<[LogLine]>(initialState: [])
        let enabled = OSAllocatedUnfairLock<Bool>(initialState: true)

        var delivery: TransportSentryReporter.Delivery {
            TransportSentryReporter.Delivery(
                isEnabled: { self.enabled.withLock { $0 } },
                addBreadcrumb: { crumb in
                    let captured = CapturedBreadcrumb(
                        category: crumb.category,
                        message: crumb.message,
                        level: crumb.level,
                        data: crumb.data?.reduce(into: [:]) { result, entry in
                            result[entry.key] = String(describing: entry.value)
                        } ?? [:]
                    )
                    self.breadcrumbs.withLock { $0.append(captured) }
                },
                capture: { event, attachment in
                    let captured = CapturedEvent(
                        title: event.message?.formatted ?? "",
                        level: event.level,
                        fingerprint: event.fingerprint,
                        tags: event.tags,
                        hasAttachment: attachment != nil,
                        attachmentFilename: attachment?.filename
                    )
                    self.events.withLock { $0.append(captured) }
                },
                log: { level, message, attributes in
                    let line = LogLine(
                        level: level,
                        message: message,
                        attributes: attributes.reduce(into: [:]) { result, entry in
                            result[entry.key] = String(describing: entry.value)
                        }
                    )
                    self.logs.withLock { $0.append(line) }
                }
            )
        }
    }

    private func makeReporter(
        recorder: Recorder,
        logsPerHour: Int = 300,
        ring: Data = Data("ring".utf8)
    ) -> TransportSentryReporter {
        TransportSentryReporter(
            role: .mobileClient,
            exportRing: { ring },
            logsPerHour: logsPerHour,
            delivery: recorder.delivery
        )
    }

    private func dialFailed(at seconds: UInt64) -> DiagnosticEvent {
        DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: seconds * Self.second,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.policyUnavailable.rawValue,
            c: 7
        )
    }

    /// Awaits the async incident-capture task without sleeping.
    private func waitForEvents(_ recorder: Recorder, _ expected: Int) async {
        for _ in 0..<1_000_000 {
            if recorder.events.withLock({ $0.count }) >= expected { return }
            await Task.yield()
        }
        #expect(recorder.events.withLock { $0.count } >= expected)
    }

    @Test func everyEventBecomesABreadcrumbAndLog() {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.ingest(DiagnosticEvent(code: .endpointStarting, tNanos: 1))
        reporter.ingest(DiagnosticEvent(code: .endpointActive, tNanos: 2))

        let crumbs = recorder.breadcrumbs.withLock { $0 }
        #expect(crumbs.count == 2)
        #expect(crumbs.allSatisfy { $0.category == "transport" })
        #expect(crumbs.map(\.message) == ["Iroh endpoint starting", "Iroh endpoint active"])
        #expect(crumbs.allSatisfy { $0.level == .info })
        #expect(crumbs[0].data["event_code"] == "endpointStarting")
        #expect(crumbs[1].data["event_code"] == "endpointActive")

        let logs = recorder.logs.withLock { $0 }
        #expect(logs.map(\.message) == ["Iroh endpoint starting", "Iroh endpoint active"])
        #expect(logs.allSatisfy { $0.level == .info })
        #expect(logs.allSatisfy { $0.attributes["transport.role"] == "iOS client" })
        #expect(logs[0].attributes["transport.event_code"] == "endpointStarting")
        #expect(logs[1].attributes["transport.event_code"] == "endpointActive")
    }

    @Test func failureEventsAreWarningsAndCaptureIncidents() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.ingest(dialFailed(at: 10))
        await waitForEvents(recorder, 1)

        let crumbs = recorder.breadcrumbs.withLock { $0 }
        #expect(crumbs.first?.level == .warning)
        #expect(
            crumbs.first?.message
                == "Transport dial failed (Transport: Iroh, Failure: Relay policy unavailable, Attempt: 7)"
        )

        let events = recorder.events.withLock { $0 }
        #expect(events.count == 1)
        let event = events[0]
        #expect(
            event.title
                == "Transport dial failed (Transport: Iroh, Failure: Relay policy unavailable, Attempt: 7)"
        )
        #expect(event.level == .warning)
        #expect(event.fingerprint == [
            "cmux-transport", "mobileClient", "transportDialFailed/policyUnavailable/iroh",
        ])
        #expect(event.tags?["transport.failure"] == "policyUnavailable")
        #expect(event.tags?["transport.kind"] == "iroh")
        #expect(event.tags?["transport.role"] == "mobileClient")
        #expect(event.tags?["transport.incident"] == "failure")
        #expect(event.hasAttachment)
        #expect(event.attachmentFilename == "cmux-transport-diag.txt")
    }

    @Test func repeatFailuresInsideCooldownDoNotCaptureAgain() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.ingest(dialFailed(at: 10))
        reporter.ingest(dialFailed(at: 20))
        reporter.ingest(dialFailed(at: 30))
        await waitForEvents(recorder, 1)

        #expect(recorder.events.withLock { $0.count } == 1)
        #expect(recorder.breadcrumbs.withLock { $0.count } == 3)
    }

    @Test func sustainedFailureStreakEscalatesToOutage() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        for t in stride(from: UInt64(10), through: 70, by: 15) {
            reporter.ingest(dialFailed(at: t))
        }
        await waitForEvents(recorder, 2)

        let events = recorder.events.withLock { $0 }
        let outage = events.first { $0.tags?["transport.incident"] == "outage" }
        #expect(outage != nil)
        #expect(outage?.level == .error)
        #expect(outage?.fingerprint == ["cmux-transport", "mobileClient", "transport-outage"])
        #expect(outage?.hasAttachment == true)
    }

    @Test func emptyRingCapturesWithoutAttachment() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder, ring: Data())

        reporter.ingest(dialFailed(at: 10))
        await waitForEvents(recorder, 1)

        #expect(recorder.events.withLock { $0.first?.hasAttachment } == false)
    }

    @Test func logBudgetDropsExcessAndReportsOnReadmission() {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder, logsPerHour: 2)

        reporter.ingest(DiagnosticEvent(code: .endpointStarting, tNanos: 1 * Self.second))
        reporter.ingest(DiagnosticEvent(code: .endpointActive, tNanos: 2 * Self.second))
        reporter.ingest(DiagnosticEvent(code: .endpointStopped, tNanos: 3 * Self.second))
        reporter.ingest(DiagnosticEvent(code: .endpointStarting, tNanos: 3800 * Self.second))

        let logs = recorder.logs.withLock { $0 }
        #expect(logs.count == 3)
        #expect(logs[2].attributes["transport.log_dropped_before_this"] == "1")
        // Breadcrumbs are unbudgeted: they only ship attached to events.
        #expect(recorder.breadcrumbs.withLock { $0.count } == 4)
    }

    @Test func simulatorEventsUseSimulatorBreadcrumbsAndSafeAttributes() {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.ingest(DiagnosticEvent(
            code: .simulatorInputLifecycle,
            tNanos: 1,
            surface: 17,
            a: DiagnosticSimulatorInputLifecycle.rejectedLocked.rawValue,
            b: DiagnosticSimulatorInputKind.hardwareButton.rawValue,
            c: DiagnosticSimulatorHardwareButtonKind.appSwitcher.rawValue
        ))

        let crumb = recorder.breadcrumbs.withLock { $0.first }
        #expect(crumb?.category == "simulator")
        #expect(crumb?.level == .warning)
        #expect(crumb?.data["diagnostic.category"] == "simulator")
        #expect(crumb?.data["event_code"] == "simulatorInputLifecycle")
        #expect(crumb?.data["surface"] == "17")
        #expect(crumb?.data["input"] == "Hardware button")
        #expect(crumb?.data["input_detail"] == "App Switcher")
        #expect(crumb?.data.keys.contains { $0.contains("text") } == false)

        let log = recorder.logs.withLock { $0.first }
        #expect(log?.level == .warning)
        #expect(log?.attributes["diagnostic.category"] == "simulator")
        #expect(log?.attributes["simulator.event_code"] == "simulatorInputLifecycle")
        #expect(log?.attributes["simulator.role"] == "iOS client")
        #expect(log?.attributes["simulator.role_code"] == "mobileClient")
        #expect(log?.attributes["simulator.surface"] == "17")
        #expect(log?.attributes["simulator.state"] == "Rejected because locked")
        #expect(log?.attributes["simulator.input"] == "Hardware button")
        #expect(log?.attributes["simulator.input_detail"] == "App Switcher")
        #expect(log?.attributes.keys.contains { $0.hasPrefix("transport.") } == false)
        #expect(recorder.events.withLock { $0.isEmpty })
    }

    @Test func appFeatureEventsUseAppNamespaceAndClassifiedSeverity() {
        let recorder = Recorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1,
            a: DiagnosticAppEventKind.workspaceOpenSucceeded.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 2,
            a: DiagnosticAppEventKind.workspaceOpenFailed.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue
        ))

        let crumbs = recorder.breadcrumbs.withLock { $0 }
        #expect(crumbs.map(\.category) == ["app", "app"])
        #expect(crumbs.map(\.level) == [.info, .warning])
        #expect(crumbs[0].data["event_code"] == "appFeatureAction")
        #expect(crumbs[0].data["operation"] == "workspaceOpenSucceeded")

        let logs = recorder.logs.withLock { $0 }
        #expect(logs.count == 2)
        #expect(logs[0].attributes["app.event_code"] == "appFeatureAction")
        #expect(logs[0].attributes["app.operation"] == "workspaceOpenSucceeded")
        #expect(logs[1].attributes["app.failure"] == "Timed out")
        #expect(logs.allSatisfy { line in
            line.attributes.keys.contains { $0.hasPrefix("transport.") } == false
        })
    }

    @Test func disabledDeliverySendsNothing() {
        let recorder = Recorder()
        recorder.enabled.withLock { $0 = false }
        let reporter = makeReporter(recorder: recorder)

        reporter.ingest(dialFailed(at: 10))

        #expect(recorder.breadcrumbs.withLock { $0.isEmpty })
        #expect(recorder.logs.withLock { $0.isEmpty })
        #expect(recorder.events.withLock { $0.isEmpty })
    }
}
