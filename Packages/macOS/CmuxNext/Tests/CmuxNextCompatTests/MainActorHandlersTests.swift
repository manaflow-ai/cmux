import CmuxNextCompat
import Testing

/// ``MainActorHandlers`` calls each registered handler and runs them outside its lock, so a handler
/// may cancel registrations (its own or another's) during a call, and a cancelled one is not called
/// again, not even later in the same call.
@MainActor @Suite struct MainActorHandlersTests {
    /// Values each handler got (main actor).
    final class Log {
        var first: [Int] = []
        var second: [Int] = []
        var registrations: [MainActorHandlerRegistration<Int>] = []
    }

    @Test func aHandlerCancelsRegistrationsDuringACall() {
        let handlers = MainActorHandlers<Int>()
        let log = Log()
        log.registrations.append(handlers.add { value in
            log.first.append(value)
            log.registrations.forEach { $0.cancel() }
        })
        log.registrations.append(handlers.add { value in
            log.second.append(value)
            log.registrations.forEach { $0.cancel() }
        })
        handlers.call(1)
        handlers.call(2)
        // The handlers run in no fixed order; whichever runs first cancels the other before its turn.
        #expect(log.first + log.second == [1], "a handler cancelled during a call still ran in that call")
        #expect(handlers.isEmpty)
    }

    @Test func releasingARegistrationStopsItsCalls() {
        let handlers = MainActorHandlers<Int>()
        let log = Log()
        var registration: MainActorHandlerRegistration<Int>? = handlers.add { value in log.first.append(value) }
        handlers.call(1)
        #expect(registration != nil)
        registration = nil
        handlers.call(2)
        #expect(log.first == [1])
        #expect(handlers.isEmpty)
    }
}
