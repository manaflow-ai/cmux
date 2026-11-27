/// Describes how much of the selected aggregate population a sample covers.
public enum MemoryPressureAggregateCoverage: String, Equatable, Sendable {
    /// Every process contributing to the selected accounting source was measured.
    case complete
    /// The reported bytes are a measured lower bound because records were missing.
    case lowerBound = "lower_bound"
    /// No measured bytes can safely describe the selected aggregate.
    case unavailable
}

/// Gives diagnostics a bounded reason for incomplete aggregate coverage.
public enum MemoryPressureAggregateMissingReason: String, Equatable, Sendable {
    /// A process record was present but its memory value was unreadable.
    case unreadableProcessRecord = "unreadable_process_record"
    /// Process enumeration reported that one or more records were not returned.
    case incompleteEnumeration = "incomplete_enumeration"
    /// A process exited or changed identity while the sample was being assembled.
    case processExitRace = "process_exit_race"
}
