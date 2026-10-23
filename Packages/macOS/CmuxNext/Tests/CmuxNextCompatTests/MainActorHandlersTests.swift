import CmuxNextCompat
import Testing

/// ``MainActorHandlers`` calls each registered handler and runs them outside its lock, so a handler
/// may cancel registrations (its own or another's) during a call, and a cancelled one gets no later value.
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
        log.registrations.append(handlers.add { value in log.second.append(value) })
        handlers.call(1)
        handlers.call(2)
        #expect(log.first == [1])
        // Both handlers were registered when 1 arrived, so the second gets it whichever runs first.
        #expect(log.second == [1])
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
