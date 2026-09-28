import Foundation

/// Marks background upkeep, such as the Cloud sidebar's periodic refresh.
/// Only connects made under it wait out a machine's failure backoff in
/// ``CloudMachineLinkManager``; anything a person or an agent asked for dials.
/// Work started by upkeep inherits the mark through task-local propagation.
public enum CloudLinkUpkeep {
    @TaskLocal public static var isBackground = false
}
