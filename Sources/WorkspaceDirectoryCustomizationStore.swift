import Foundation

/// Persists user-owned workspace identity independently from live workspace and session lifetimes.
@MainActor
final class WorkspaceDirectoryCustomizationStore {
    static let defaultStorageKey = "workspaceDirectoryCustomizations.v1"

    private let defaults: UserDefaults?
    private let storageKey: String
    private var customizationsByDirectory: [String: WorkspaceDirectoryCustomization]

    init(
        defaults: UserDefaults? = nil,
        storageKey: String = WorkspaceDirectoryCustomizationStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults?.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: WorkspaceDirectoryCustomization].self,
               from: data
           ) {
            customizationsByDirectory = decoded
        } else {
            customizationsByDirectory = [:]
        }
    }

    func directoryKey(for directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
            .precomposedStringWithCanonicalMapping
        return standardized.isEmpty ? nil : standardized
    }

    func customization(for directory: String?) -> WorkspaceDirectoryCustomization? {
        guard let key = directoryKey(for: directory) else { return nil }
        return customizationsByDirectory[key]
    }

    func setCustomTitle(_ title: String?, for directory: String?) {
        guard let key = directoryKey(for: directory) else { return }
        let normalizedTitle = normalizedValue(title)
        let current = customizationsByDirectory[key]
        setCustomization(
            WorkspaceDirectoryCustomization(
                customTitle: normalizedTitle,
                customColor: current?.customColor
            ),
            forKey: key
        )
    }

    func setCustomColor(_ color: String?, for directory: String?) {
        guard let key = directoryKey(for: directory) else { return }
        let normalizedColor = normalizedValue(color)
        let current = customizationsByDirectory[key]
        setCustomization(
            WorkspaceDirectoryCustomization(
                customTitle: current?.customTitle,
                customColor: normalizedColor
            ),
            forKey: key
        )
    }

    private func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func setCustomization(
        _ customization: WorkspaceDirectoryCustomization,
        forKey key: String
    ) {
        if customization.isEmpty {
            customizationsByDirectory.removeValue(forKey: key)
        } else {
            customizationsByDirectory[key] = customization
        }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        guard !customizationsByDirectory.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(customizationsByDirectory) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
