import Foundation

// MARK: - Profile Model

struct Profile: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var snapshot: SessionTabManagerSnapshot

    init(name: String, snapshot: SessionTabManagerSnapshot) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.snapshot = snapshot
    }
}

// MARK: - Profile Store

enum ProfileStore {
    static let maxProfiles = 24

    /// Lists all saved profiles sorted by name.
    static func list() -> [Profile] {
        guard let directory = profilesDirectory() else { return [] }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var profiles: [Profile] = []
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let profile = try? decoder.decode(Profile.self, from: data) else {
                continue
            }
            profiles.append(profile)
        }

        return profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Loads a profile by name.
    static func load(name: String) -> Profile? {
        guard let fileURL = profileFileURL(for: name) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Profile.self, from: data)
    }

    /// Loads a profile by ID.
    static func load(id: UUID) -> Profile? {
        list().first { $0.id == id }
    }

    /// Saves a profile. Overwrites any existing profile with the same name.
    /// Returns true on success.
    @discardableResult
    static func save(_ profile: Profile) -> Bool {
        guard let directory = profilesDirectory() else { return false }
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        // Enforce max profile limit (don't count existing profile being overwritten).
        let existing = list()
        let isOverwrite = existing.contains { $0.name == profile.name }
        if !isOverwrite && existing.count >= maxProfiles {
            return false
        }

        guard let fileURL = profileFileURL(for: profile.name) else { return false }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        do {
            let data = try encoder.encode(profile)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Saves the current TabManager state as a named profile.
    @MainActor
    static func saveCurrentSession(
        name: String,
        tabManager: TabManager,
        includeScrollback: Bool = true
    ) -> Profile? {
        let snapshot = tabManager.sessionSnapshot(includeScrollback: includeScrollback)
        guard !snapshot.workspaces.isEmpty else { return nil }
        var profile = Profile(name: name, snapshot: snapshot)

        // If overwriting an existing profile, preserve its ID and creation date.
        if let existing = load(name: name) {
            profile.id = existing.id
            profile.createdAt = existing.createdAt
        }
        profile.updatedAt = Date()

        guard save(profile) else { return nil }
        return profile
    }

    /// Deletes a profile by name. Returns true if the file was removed.
    @discardableResult
    static func delete(name: String) -> Bool {
        guard let fileURL = profileFileURL(for: name) else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// Renames a profile. Returns the updated profile on success.
    static func rename(oldName: String, newName: String) -> Profile? {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return nil }
        guard var profile = load(name: oldName) else { return nil }

        // If the new name already exists (and it's not the same file), bail.
        if trimmedNew != oldName, load(name: trimmedNew) != nil {
            return nil
        }

        // Delete old file first (the filename is derived from the name).
        delete(name: oldName)

        profile.name = trimmedNew
        profile.updatedAt = Date()
        guard save(profile) else { return nil }
        return profile
    }

    // MARK: - Private

    private static func profilesDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }

    /// Derives a filesystem-safe filename from a profile name.
    private static func profileFileURL(for name: String) -> URL? {
        guard let directory = profilesDirectory() else { return nil }
        let sanitized = sanitizedFileName(name)
        guard !sanitized.isEmpty else { return nil }
        return directory
            .appendingPathComponent(sanitized, isDirectory: false)
            .appendingPathExtension("json")
    }

    /// Creates a filesystem-safe version of a profile name.
    private static func sanitizedFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Replace characters that are problematic in filenames.
        let sanitized = trimmed.replacingOccurrences(
            of: "[/\\\\:*?\"<>|]",
            with: "_",
            options: .regularExpression
        )
        // Limit length to avoid filesystem issues.
        let maxLength = 128
        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        return sanitized
    }
}
