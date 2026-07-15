import Foundation

/// The globally saved commands available to Settings, layouts, and the command palette.
public struct SavedTerminalCommandLibrary: Sendable, Equatable, SettingCodable {
    /// Commands in their user-defined display order.
    public private(set) var commands: [SavedTerminalCommand]

    /// Creates a saved-command library.
    ///
    /// - Parameter commands: Commands in display order.
    public init(commands: [SavedTerminalCommand] = []) {
        self.commands = commands
    }

    /// Returns the command with a case-insensitively matching name.
    ///
    /// - Parameter name: Saved command name to find.
    /// - Returns: The matching command, or `nil` when no command matches.
    public func command(named name: String?) -> SavedTerminalCommand? {
        guard let name else { return nil }
        return commands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether `name` can be saved for `id` without duplicating another command name.
    ///
    /// - Parameters:
    ///   - name: Candidate command name.
    ///   - id: Identity being added or edited.
    /// - Returns: `true` when the trimmed name is nonempty and unique.
    public func canSave(name: String, id: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }
        return !commands.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    /// Adds a command or replaces the command with the same identity in place.
    ///
    /// Duplicate names are rejected case-insensitively so command-palette lookup
    /// remains deterministic.
    ///
    /// - Parameter command: Command to add or replace.
    /// - Returns: `true` when the command was saved; otherwise `false`.
    @discardableResult
    public mutating func save(_ command: SavedTerminalCommand) -> Bool {
        let normalizedName = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave(name: normalizedName, id: command.id),
              !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = SavedTerminalCommand(
            id: command.id,
            name: normalizedName,
            command: command.command
        )
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = normalized
        } else {
            commands.append(normalized)
        }
        return true
    }

    /// Removes the command with `id` when present.
    ///
    /// - Parameter id: Stable command identity to remove.
    public mutating func remove(id: String) {
        commands.removeAll { $0.id == id }
    }

    /// Decodes a library from its property-list array representation.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        [SavedTerminalCommand].decodeFromUserDefaults(raw).map(Self.init(commands:))
    }

    /// Encodes the library as a property-list array.
    public func encodeForUserDefaults() -> Any {
        commands.encodeForUserDefaults()
    }

    /// Decodes a library from its JSON array representation.
    public static func decodeFromJSON(_ raw: Any?) -> Self? {
        [SavedTerminalCommand].decodeFromJSON(raw).map(Self.init(commands:))
    }

    /// Encodes the library as a JSON array.
    public func encodeForJSON() -> Any {
        commands.encodeForJSON()
    }
}
