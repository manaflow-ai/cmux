import Foundation
import SwiftUI

/// A saved workspace color profile, similar to Terminal.app profiles.
struct WorkspaceProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var accentColor: String     // hex like "#5BA4CF"
    var backgroundColor: String // hex like "#0d1117"
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, accentColor: String, backgroundColor: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.isBuiltIn = isBuiltIn
    }

    /// Create from a WorkspaceTheme preset.
    init(theme: WorkspaceTheme) {
        self.id = UUID()
        self.name = theme.name.capitalized
        self.accentColor = theme.accentColor
        self.backgroundColor = theme.backgroundColor
        self.isBuiltIn = true
    }
}

/// Manages workspace color profiles. Persists custom profiles to UserDefaults.
final class WorkspaceProfileStore: ObservableObject {
    static let shared = WorkspaceProfileStore()
    private static let storageKey = "workspaceProfiles"

    @Published var profiles: [WorkspaceProfile] = []

    private init() {
        profiles = Self.load()
        if profiles.isEmpty {
            profiles = Self.builtInProfiles()
            save()
        }
    }

    /// Built-in profiles from WorkspaceTheme presets.
    static func builtInProfiles() -> [WorkspaceProfile] {
        WorkspaceTheme.presetNames.map { name in
            let theme = WorkspaceTheme.named(name)!
            return WorkspaceProfile(theme: theme)
        }
    }

    func add(_ profile: WorkspaceProfile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: WorkspaceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func profile(named name: String) -> WorkspaceProfile? {
        profiles.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Apply a profile's colors to a workspace.
    @MainActor static func apply(_ profile: WorkspaceProfile, to workspace: Workspace) {
        workspace.accentColor = profile.accentColor
        workspace.backgroundColorOverride = profile.backgroundColor
        workspace.applyBackgroundColorOverride()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> [WorkspaceProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profiles = try? JSONDecoder().decode([WorkspaceProfile].self, from: data) else {
            return []
        }
        return profiles
    }
}
