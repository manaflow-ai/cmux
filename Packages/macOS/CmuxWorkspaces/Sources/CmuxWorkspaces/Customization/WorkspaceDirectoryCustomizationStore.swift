public import Foundation

/// Persists user-owned workspace identity independently from live workspace and session lifetimes.
///
/// `UserDefaults` is the sole source of truth. The store deliberately keeps no
/// in-memory mirror, so independently constructed window graphs cannot drift.
public struct WorkspaceDirectoryCustomizationStore: Sendable {
    /// The production defaults key for the encoded directory map.
    public static let defaultStorageKey = "workspaceDirectoryCustomizations.v1"

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults?
    private let storageKey: String

    /// Creates a store backed by the supplied defaults suite.
    ///
    /// Passing `nil` creates a no-op store, which is the default for isolated
    /// `TabManager` tests that do not exercise durable customization.
    ///
    /// - Parameters:
    ///   - defaults: The defaults suite that owns the directory map.
    ///   - storageKey: The key under which the encoded map is stored.
    public init(
        defaults: UserDefaults? = nil,
        storageKey: String = WorkspaceDirectoryCustomizationStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Returns the normalized stable key for a workspace root directory.
    ///
    /// - Parameter directory: A workspace root path.
    /// - Returns: A standardized, canonically composed path, or `nil` for a blank path.
    public func directoryKey(for directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
            .precomposedStringWithCanonicalMapping
        return standardized.isEmpty ? nil : standardized
    }

    /// Reads the sticky identity for a workspace root directory.
    ///
    /// - Parameter directory: A workspace root path or an already normalized key.
    /// - Returns: The stored customization, or `nil` when none exists.
    public func customization(for directory: String?) -> WorkspaceDirectoryCustomization? {
        guard let key = directoryKey(for: directory) else { return nil }
        return loadCustomizations()[key]
    }

    /// Persists or clears the explicit label for a workspace root.
    ///
    /// - Parameters:
    ///   - title: The label to persist; blank text clears the label.
    ///   - directory: The workspace root directory.
    public func setCustomTitle(_ title: String?, for directory: String?) {
        guard let key = directoryKey(for: directory) else { return }
        let normalizedTitle = normalizedValue(title)
        var customizations = loadCustomizations()
        let current = customizations[key]
        setCustomization(
            WorkspaceDirectoryCustomization(
                customTitle: normalizedTitle,
                customColor: current?.customColor
            ),
            forKey: key,
            in: &customizations
        )
    }

    /// Persists or clears the explicit color for a workspace root.
    ///
    /// - Parameters:
    ///   - color: The color to persist; blank text clears the color.
    ///   - directory: The workspace root directory.
    public func setCustomColor(_ color: String?, for directory: String?) {
        guard let key = directoryKey(for: directory) else { return }
        let normalizedColor = normalizedValue(color)
        var customizations = loadCustomizations()
        let current = customizations[key]
        setCustomization(
            WorkspaceDirectoryCustomization(
                customTitle: current?.customTitle,
                customColor: normalizedColor
            ),
            forKey: key,
            in: &customizations
        )
    }

    private func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func setCustomization(
        _ customization: WorkspaceDirectoryCustomization,
        forKey key: String,
        in customizations: inout [String: WorkspaceDirectoryCustomization]
    ) {
        if customization.isEmpty {
            customizations.removeValue(forKey: key)
        } else {
            customizations[key] = customization
        }
        persist(customizations)
    }

    private func loadCustomizations() -> [String: WorkspaceDirectoryCustomization] {
        guard let data = defaults?.data(forKey: storageKey) else { return [:] }
        // Invalid legacy/corrupt preference bytes behave as an empty map; the
        // next explicit mutation rewrites the single owned defaults value.
        return (try? JSONDecoder().decode(
            [String: WorkspaceDirectoryCustomization].self,
            from: data
        )) ?? [:]
    }

    private func persist(_ customizations: [String: WorkspaceDirectoryCustomization]) {
        guard let defaults else { return }
        guard !customizations.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(customizations) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
