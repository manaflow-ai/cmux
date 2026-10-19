public import Foundation
import Observation

/// Owns disclosure choices for provider-rendered sidebar sections.
///
/// Sections default to expanded. The app injects one store into every window so
/// choices update every sidebar and survive relaunch; tests pass isolated defaults.
/// Missing sections retain their choices until the oldest entries are evicted
/// by the 1,000-section limit.
///
/// ```swift
/// let store = SidebarSectionDisclosureStore(defaults: isolatedDefaults)
/// store.setCollapsed(true, providerID: "projects", sectionID: "project-root")
/// ```
@MainActor @Observable
public final class SidebarSectionDisclosureStore {
    static let preferenceKey = "sidebar.collapsedProviderSections"
    static let maximumRememberedSections = 1_000

    private let defaults: UserDefaults
    /// Oldest-first pairs avoid collisions between arbitrary provider and section IDs.
    private var collapsedSections: [[String]]
    private var collapsedSectionMembership: Set<[String]>

    /// Creates disclosure state with app-supplied preferences.
    /// - Parameter defaults: The app preferences, or an isolated suite in tests.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Self.preferenceKey) as? [[String]] ?? []
        var seen: Set<[String]> = []
        let normalized = Array(stored.reversed()
            .filter { $0.count == 2 && seen.insert($0).inserted }
            .prefix(Self.maximumRememberedSections)
            .reversed())
        collapsedSections = normalized
        collapsedSectionMembership = Set(normalized)
        if collapsedSections != stored {
            defaults.set(collapsedSections, forKey: Self.preferenceKey)
        }
    }

    /// Returns whether a section's children are hidden.
    /// - Parameters:
    ///   - providerID: The provider's stable identifier.
    ///   - sectionID: The section's stable identifier within that provider.
    /// - Returns: `false` for sections without a collapse choice.
    public func isCollapsed(providerID: String, sectionID: String) -> Bool {
        collapsedSectionMembership.contains([providerID, sectionID])
    }

    /// Persists a disclosure choice and updates all observers of this store.
    ///
    /// Expanding removes the remembered collapse. Collapsing a new section at
    /// capacity evicts the oldest collapse choice, including absent sections.
    /// - Parameters:
    ///   - collapsed: Whether to hide the children.
    ///   - providerID: The provider's stable identifier.
    ///   - sectionID: The section's stable identifier within that provider.
    public func setCollapsed(_ collapsed: Bool, providerID: String, sectionID: String) {
        let key = [providerID, sectionID]
        var next = collapsedSections
        if collapsed {
            guard !collapsedSectionMembership.contains(key) else { return }
            next.append(key)
            if next.count > Self.maximumRememberedSections {
                next.removeFirst(next.count - Self.maximumRememberedSections)
            }
        } else {
            next.removeAll { $0 == key }
        }
        guard next != collapsedSections else { return }
        collapsedSections = next
        collapsedSectionMembership = Set(next)
        defaults.set(next, forKey: Self.preferenceKey)
    }
}
