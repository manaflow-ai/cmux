import Sentry
import Testing

@testable import CmuxSentryReporting

@Suite struct TransportSentryEventNoiseFilterTests {
    private let filter = TransportSentryEventNoiseFilter()

    @Test(arguments: [
        "socket.listener.unhealthy",
        "socket.listener.accept.failed",
    ])
    func dropsOperationalListenerMessages(_ message: String) {
        #expect(filter.shouldDrop(message: message))
    }

    @Test(arguments: [
        "App Hanging: App hanging for at least 8000 ms.",
        "EXC_BAD_ACCESS",
        "Failed to write to socket",
    ])
    func keepsCrashesAndActionableErrors(_ message: String) {
        #expect(!filter.shouldDrop(message: message))
    }

    @Test func dropsOfflineTransportEventsButKeepsOtherSampledEvents() {
        let offline = Event(level: .warning)
        offline.logger = "cmux.transport"
        offline.tags = [
            "transport.failure": "offline",
            "transport.incident": "failure",
        ]
        #expect(filter.filter(offline) == nil)

        let actionable = Event(level: .warning)
        actionable.logger = "cmux.transport"
        actionable.tags = [
            "transport.failure": "policyUnavailable",
            "transport.incident": "failure",
        ]
        #expect(filter.filter(actionable) != nil)
    }

    @Test func staleOfflineSnapshotDoesNotDropActionableProtocolFailures() {
        let actionable = Event(level: .warning)
        actionable.logger = "cmux.transport"
        actionable.tags = [
            "transport.failure": "identityMismatch",
            "transport.incident": "failure",
        ]
        actionable.context = [
            "cmux.transport": ["reachable": false],
        ]

        #expect(filter.filter(actionable) != nil)

        let environmental = Event(level: .warning)
        environmental.logger = "cmux.transport"
        environmental.tags = [
            "transport.failure": "endpointUnavailable",
            "transport.incident": "failure",
        ]
        environmental.context = [
            "cmux.transport": ["reachable": false],
        ]

        #expect(filter.filter(environmental) == nil)
    }

    @Test func filtersListenerMessagesBeforeLoggerCheck() {
        let event = Event(level: .error)
        event.logger = "cmux.app"
        event.message = SentryMessage(formatted: "socket.listener.accept.failed")
        // Listener filtering is intentionally message-based even for events
        // without the transport logger.
        #expect(filter.filter(event) == nil)

        let crash = Event(level: .error)
        crash.logger = "cmux.app"
        crash.message = SentryMessage(formatted: "EXC_BAD_ACCESS")
        #expect(filter.filter(crash) != nil)
    }

    @Test func preservesListenerStartFailureForCooldownAdmission() {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "socket.listener.start.failed")
        #expect(filter.filter(event) != nil)
    }
}
