#if os(iOS)
public import SwiftUI

/// Tells the app when the user starts and finishes moving a scrolling list.
///
/// Work that stalls the main thread for a few frames goes unnoticed while
/// content rests but reads as a jump mid-fling. The app root injects this so
/// such work (session replay capture) can wait for the scroll to settle.
public struct MobileScrollInteractionReporter: Sendable {
    public let interactionChanged: @MainActor @Sendable (_ isActive: Bool) -> Void

    public init(interactionChanged: @escaping @MainActor @Sendable (_ isActive: Bool) -> Void) {
        self.interactionChanged = interactionChanged
    }
}

private struct MobileScrollInteractionReporterKey: EnvironmentKey {
    static let defaultValue: MobileScrollInteractionReporter? = nil
}

extension EnvironmentValues {
    /// Receives scroll start and settle events from list surfaces.
    public var scrollInteractionReporter: MobileScrollInteractionReporter? {
        get { self[MobileScrollInteractionReporterKey.self] }
        set { self[MobileScrollInteractionReporterKey.self] = newValue }
    }
}
#endif
