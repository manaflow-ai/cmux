/// Mutable observation callback flag confined to MainActor-isolated tests.
final class ObservationFlag: @unchecked Sendable {
    // The owning suites are MainActor-isolated, so callbacks and assertions
    // access this flag serially despite Observation's Sendable closure.
    var fired = false
}
