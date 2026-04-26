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

// MARK: - Profile List Cache

/// Caches the profile list to avoid blocking the main thread on menu rebuilds.
/// Refreshes asynchronously after mutations.
@MainActor
final class ProfileListCache: ObservableObject {
    static let shared = ProfileListCache()

    @Published private(set) var profiles: [Profile] = []

    /// Generation counter to prevent out-of-order refresh completion from overwriting newer data.
    private var refreshGeneration: UInt64 = 0

    private init() {
        // Initial load
        refresh()
    }

    /// Refreshes the cached profile list asynchronously.
    /// Uses a generation counter to ensure only the latest refresh updates the cache.
    func refresh() {
        refreshGeneration &+= 1
        let myGeneration = refreshGeneration
        Task.detached(priority: .userInitiated) {
            let freshList = ProfileStore.list()
            await MainActor.run {
                // Only update if no newer refresh was requested
                guard myGeneration == self.refreshGeneration else { return }
                self.profiles = freshList
            }
        }
    }
}

// MARK: - Profile Store

enum ProfileStore {
    static let maxProfiles = 24

    /// Serial queue for all profile I/O operations to prevent races between
    /// concurrent save/load/delete/rename calls.
    private static let ioQueue = DispatchQueue(label: "com.cmux.ProfileStore.io", qos: .utility)

    /// Lists all saved profiles sorted by name.
    static func list() -> [Profile] {
        ioQueue.sync {
            listUnsafe()
        }
    }

    /// Internal list implementation without queue synchronization.
    /// Only call from within ioQueue or other synchronized context.
    private static func listUnsafe() -> [Profile] {
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
    /// Returns nil if no profile exists or if the decoded profile's name doesn't match
    /// (can happen when different names map to the same sanitized filename).
    /// Names are normalized (trimmed) before comparison to match profileFileURL behavior.
    static func load(name: String) -> Profile? {
        ioQueue.sync {
            loadUnsafe(name: name)
        }
    }

    /// Internal load implementation without queue synchronization.
    /// Only call from within ioQueue or other synchronized context.
    private static func loadUnsafe(name: String) -> Profile? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        guard let fileURL = profileFileURL(for: normalizedName) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let profile = try? decoder.decode(Profile.self, from: data) else { return nil }
        // Validate the decoded profile's name matches the requested name (both normalized).
        // Multiple names can map to the same sanitized filename (e.g., case differences),
        // so we must verify we're returning the correct logical profile.
        let normalizedProfileName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedProfileName == normalizedName else { return nil }
        return profile
    }

    /// Loads a profile by ID.
    static func load(id: UUID) -> Profile? {
        ioQueue.sync {
            listUnsafe().first { $0.id == id }
        }
    }

    /// Saves a profile. Overwrites any existing profile with the same name.
    /// Returns true on success.
    @discardableResult
    static func save(_ profile: Profile) -> Bool {
        let result = ioQueue.sync {
            saveUnsafe(profile)
        }
        if result {
            Task { @MainActor in ProfileListCache.shared.refresh() }
        }
        return result
    }

    /// Internal save implementation without queue synchronization.
    /// Only call from within ioQueue or other synchronized context.
    private static func saveUnsafe(_ profile: Profile) -> Bool {
        guard let directory = profilesDirectory() else { return false }
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        // Enforce max profile limit (don't count existing profile being overwritten or renamed).
        // Use sanitized filenames for collision detection since that's how files are stored.
        let existing = listUnsafe()
        guard let targetFileURL = profileFileURL(for: profile.name) else { return false }
        let targetFileName = sanitizedFileName(profile.name).lowercased()
        let collidingProfile = existing.first {
            sanitizedFileName($0.name).lowercased() == targetFileName
        }
        if let collidingProfile {
            // Allow overwrite if same name or same ID (rename). Reject if a
            // different profile maps to the same sanitized filename
            // (case-insensitive, since macOS filesystems are case-insensitive by default).
            guard collidingProfile.name == profile.name || collidingProfile.id == profile.id else {
                return false
            }
        }
        // Check if this is an overwrite (same filename) or a rename (same ID, different filename).
        // Both cases don't increase the profile count, so they're allowed at max capacity.
        let isOverwrite = collidingProfile != nil
        let isRename = existing.contains { $0.id == profile.id }
        if !isOverwrite && !isRename && existing.count >= maxProfiles {
            return false
        }

        let fileURL = targetFileURL

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
        // Capture snapshot on main actor (requires TabManager access)
        let snapshot = tabManager.sessionSnapshot(includeScrollback: includeScrollback)
        guard !snapshot.workspaces.isEmpty else { return nil }

        // Perform I/O atomically on serial queue
        let result: Profile? = ioQueue.sync {
            var profile = Profile(name: name, snapshot: snapshot)

            // If overwriting an existing profile, preserve its ID and creation date.
            if let existing = loadUnsafe(name: name) {
                profile.id = existing.id
                profile.createdAt = existing.createdAt
            }
            profile.updatedAt = Date()

            guard saveUnsafe(profile) else { return nil }
            return profile
        }
        if result != nil {
            ProfileListCache.shared.refresh()
        }
        return result
    }

    /// Async version of saveCurrentSession that moves disk I/O off the main actor.
    /// Captures the snapshot on main, then performs load/save work on a serial queue.
    /// Use this for autosave paths where blocking the main thread is undesirable.
    @MainActor
    static func saveCurrentSessionAsync(
        name: String,
        tabManager: TabManager,
        includeScrollback: Bool = false
    ) async -> Profile? {
        // Capture snapshot on main actor (requires TabManager access)
        let snapshot = tabManager.sessionSnapshot(includeScrollback: includeScrollback)
        guard !snapshot.workspaces.isEmpty else { return nil }

        // Move heavy I/O work to serial queue to prevent races with concurrent operations
        let result: Profile? = await withCheckedContinuation { continuation in
            ioQueue.async {
                var profile = Profile(name: name, snapshot: snapshot)

                // If overwriting an existing profile, preserve its ID and creation date.
                // Use unsafe variants since we're already on ioQueue.
                if let existing = loadUnsafe(name: name) {
                    profile.id = existing.id
                    profile.createdAt = existing.createdAt
                }
                profile.updatedAt = Date()

                // save() does JSON encoding and disk write.
                guard saveUnsafe(profile) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: profile)
            }
        }
        if result != nil {
            ProfileListCache.shared.refresh()
        }
        return result
    }

    /// Deletes a profile by name. Returns true if the file was removed.
    /// Validates the file contains a profile with the exact requested name before deleting.
    @discardableResult
    static func delete(name: String) -> Bool {
        let result = ioQueue.sync {
            deleteUnsafe(name: name)
        }
        if result {
            Task { @MainActor in ProfileListCache.shared.refresh() }
        }
        return result
    }

    /// Internal delete implementation without queue synchronization.
    /// Only call from within ioQueue or other synchronized context.
    private static func deleteUnsafe(name: String) -> Bool {
        // Verify the profile exists and has the exact name we're deleting.
        // This prevents deleting a different profile when names map to the same sanitized filename.
        guard loadUnsafe(name: name) != nil else { return false }
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

        // Perform entire rename atomically on serial queue
        let result: Profile? = ioQueue.sync {
            guard var profile = loadUnsafe(name: oldName) else { return nil }

            // If the new name maps to a different file that already exists, bail.
            // Allow case-only renames on case-insensitive filesystems by comparing lowercased sanitized names.
            let oldSanitized = sanitizedFileName(oldName)
            let newSanitized = sanitizedFileName(trimmedNew)
            if oldSanitized.lowercased() != newSanitized.lowercased(), loadUnsafe(name: trimmedNew) != nil {
                return nil
            }

            // Save the new file first, then delete the old one to avoid data loss.
            profile.name = trimmedNew
            profile.updatedAt = Date()
            guard saveUnsafe(profile) else { return nil }

            // Delete the old file if it still exists and is different from the new file.
            // On case-insensitive filesystems, save() overwrites the old file for case-only renames.
            // On case-sensitive filesystems, the old file remains and must be explicitly deleted.
            // Use file resource identifiers (inode) to detect same-file, not path strings.
            if let oldFileURL = profileFileURL(for: oldName),
               let newFileURL = profileFileURL(for: trimmedNew),
               FileManager.default.fileExists(atPath: oldFileURL.path) {
                let oldId = try? oldFileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
                let newId = try? newFileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
                guard let oldId, let newId else {
                    // Cannot determine file identity. Do NOT delete anything here:
                    // on case-insensitive filesystems with case-only renames, the save
                    // already overwrote the single file, so deleting would cause data loss.
                    // Return success since save succeeded. Worst case: duplicate files on
                    // case-sensitive filesystems, which is better than data loss.
                    return profile
                }
                if !oldId.isEqual(newId) {
                    guard deleteUnsafe(name: oldName) else {
                        // Roll back: remove the newly saved file to avoid duplicates.
                        _ = deleteUnsafe(name: trimmedNew)
                        return nil
                    }
                }
            }
            return profile
        }
        if result != nil {
            Task { @MainActor in ProfileListCache.shared.refresh() }
        }
        return result
    }

    // MARK: - Test Isolation

    /// Override for test isolation. When set, all file operations use this
    /// directory instead of the real Application Support path.
    static var overrideProfilesDirectory: URL?

    // MARK: - Private

    private static func profilesDirectory() -> URL? {
        if let override = overrideProfilesDirectory { return override }
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
        var sanitized = trimmed.replacingOccurrences(
            of: "[/\\\\:*?\"<>|]",
            with: "_",
            options: .regularExpression
        )
        // Strip leading dots to prevent hidden files on Unix filesystems.
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        guard !sanitized.isEmpty else { return "_" }
        // Limit length to avoid filesystem issues.
        let maxLength = 128
        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        return sanitized
    }
}
