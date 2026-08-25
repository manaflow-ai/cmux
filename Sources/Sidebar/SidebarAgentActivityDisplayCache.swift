import Foundation

/// Bounded main-actor cache shared by realized SwiftUI and AppKit labels.
///
/// Every label still invalidates only when its compact elapsed bucket changes,
/// while rows that share a bucket reuse the same localized string payload.
@MainActor
final class SidebarAgentActivityDisplayCache {
    private typealias Key = String

    private static let maximumEntries = 128
    private var values: [Key: SidebarAgentActivityDisplayPayload] = [:]
    private var insertionOrder: [Key] = []

    func payload(
        for activity: SidebarWorkspaceAgentActivity,
        at now: Date
    ) -> SidebarAgentActivityDisplayPayload {
        guard activity.primaryState == .running,
              let elapsed = activity.elapsed(at: now) else {
            return SidebarAgentActivityDisplayPayload(activity: activity, at: now)
        }

        let key = [
            SidebarAgentResolvedState.running.rawValue,
            String(SidebarWorkspaceAgentActivity.compactElapsedDisplayBucket(elapsed)),
            Locale.current.identifier,
        ].joined(separator: "|")
        if let cached = values[key] {
            return cached
        }

        let value = SidebarAgentActivityDisplayPayload(activity: activity, at: now)
        values[key] = value
        insertionOrder.append(key)
        if insertionOrder.count > Self.maximumEntries,
           let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            values.removeValue(forKey: oldest)
        }
        return value
    }
}
