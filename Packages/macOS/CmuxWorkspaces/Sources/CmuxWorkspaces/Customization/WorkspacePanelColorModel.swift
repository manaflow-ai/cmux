public import Foundation
public import Observation

/// Owns the normalized custom colors assigned to one workspace's panels.
///
/// ```swift
/// let colors = WorkspacePanelColorModel()
/// colors.setColor("#12ab34", forPanelID: panelID)
/// let snapshot = colors.snapshot
/// ```
@MainActor
@Observable
public final class WorkspacePanelColorModel {
    private var storage: [UUID: String] = [:]

    /// Creates an empty panel-color model.
    public init() {}

    /// An immutable value snapshot of the currently assigned panel colors.
    public var snapshot: [UUID: String] {
        storage
    }

    /// Returns the normalized custom color assigned to a panel.
    /// - Parameter panelID: The panel whose color should be read.
    /// - Returns: A `#RRGGBB` color, or `nil` when the panel has no assignment.
    public func color(forPanelID panelID: UUID) -> String? {
        storage[panelID]
    }

    /// Assigns or clears one panel's custom color.
    /// - Parameters:
    ///   - rawColor: A six-digit hexadecimal color, or `nil` to clear it.
    ///   - panelID: The panel whose assignment should change.
    /// - Returns: `true` when the input was accepted, including a no-op or
    ///   clear; `false` when a non-`nil` color was invalid.
    @discardableResult
    public func setColor(_ rawColor: String?, forPanelID panelID: UUID) -> Bool {
        let normalizedColor: String?
        if let rawColor {
            guard let normalized = WorkspaceTabColorInputResolver.normalizedHex(rawColor) else {
                return false
            }
            normalizedColor = normalized
        } else {
            normalizedColor = nil
        }

        guard storage[panelID] != normalizedColor else { return true }
        if let normalizedColor {
            storage[panelID] = normalizedColor
        } else {
            storage.removeValue(forKey: panelID)
        }
        return true
    }

    /// Removes any color assigned to a panel.
    /// - Parameter panelID: The panel whose assignment should be removed.
    public func removeColor(forPanelID panelID: UUID) {
        guard storage[panelID] != nil else { return }
        storage.removeValue(forKey: panelID)
    }

    /// Removes assignments for panels outside the supplied live-panel set.
    /// - Parameter panelIDs: The panel identifiers whose colors should remain.
    public func retainColors(forPanelIDs panelIDs: Set<UUID>) {
        let retainedStorage = storage.filter { panelIDs.contains($0.key) }
        guard retainedStorage.count != storage.count else { return }
        storage = retainedStorage
    }
}
