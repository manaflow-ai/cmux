public import Foundation

/// Persists user-owned workspace identity independently from live workspace and session lifetimes.
///
/// `UserDefaults` is the sole source of truth. The store deliberately keeps no
/// in-memory mirror, so independently constructed window graphs cannot drift.
@MainActor
public struct WorkspaceDirectoryCustomizationStore {
    /// The production defaults key for the encoded directory map.
    public nonisolated static let defaultStorageKey = "workspaceDirectoryCustomizations.v1"

    private let defaults: UserDefaults?
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
        let normalizedTitle = normalizedValue(title)
        updateCustomization(for: directory) { current in
            WorkspaceDirectoryCustomization(
                customTitle: normalizedTitle,
                customColor: current?.customColor
            )
        }
    }

    /// Persists or clears the explicit color for a workspace root.
    ///
    /// - Parameters:
    ///   - color: The color to persist; blank text clears the color.
    ///   - directory: The workspace root directory.
    public func setCustomColor(_ color: String?, for directory: String?) {
        guard let directory else { return }
        setCustomColor(color, forDirectories: [directory])
    }

    /// Persists or clears one explicit color across multiple workspace roots.
    ///
    /// The directory map is read and written once for the whole user action.
    ///
    /// - Parameters:
    ///   - color: The color to persist; blank text clears the color.
    ///   - directories: The workspace root directories to update.
    public func setCustomColor(_ color: String?, forDirectories directories: [String]) {
        let keys = Set(directories.compactMap { directoryKey(for: $0) })
        guard !keys.isEmpty else { return }
        let normalizedColor = normalizedValue(color)
        updateCustomizations(forKeys: keys) { current in
            WorkspaceDirectoryCustomization(
                customTitle: current?.customTitle,
                customColor: normalizedColor
            )
        }
    }

    /// Atomically updates both sticky identity fields for one workspace root.
    ///
    /// The transform receives the current value and its result becomes the
    /// complete record. Returning an empty customization removes the record.
    ///
    /// - Parameters:
    ///   - directory: The workspace root directory.
    ///   - transform: A synchronous mutation of the current customization.
    /// - Returns: The normalized stored value, or `nil` when the record was removed.
    @discardableResult
    public func updateCustomization(
        for directory: String?,
        _ transform: (WorkspaceDirectoryCustomization?) -> WorkspaceDirectoryCustomization
    ) -> WorkspaceDirectoryCustomization? {
        guard let key = directoryKey(for: directory) else { return nil }
        var result: WorkspaceDirectoryCustomization?
        updateCustomizations(forKeys: [key]) { current in
            let customization = transform(current)
            let normalized = WorkspaceDirectoryCustomization(
                customTitle: normalizedValue(customization.customTitle),
                customColor: normalizedValue(customization.customColor)
            )
            result = normalized.isEmpty ? nil : normalized
            return normalized
        }
        return result
    }

    private func updateCustomizations(
        forKeys keys: Set<String>,
        transform: (WorkspaceDirectoryCustomization?) -> WorkspaceDirectoryCustomization
    ) {
        var customizations = loadCustomizations()
        for key in keys {
            setCustomization(
                transform(customizations[key]),
                forKey: key,
                in: &customizations
            )
        }
        persist(customizations)
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
