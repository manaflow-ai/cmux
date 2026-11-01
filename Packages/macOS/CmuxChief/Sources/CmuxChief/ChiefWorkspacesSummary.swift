public import Foundation

/// The "Workspaces when this conversation started" section of the system
/// prompt (``ChiefPromptContext/workspacesSummary``): one line per workspace,
/// so a first question rarely needs a `cmux tree` round trip.
///
/// Model-facing text: not localized.
///
/// ```swift
/// let text = ChiefWorkspacesSummary(lines: lines).render()
/// ```
public struct ChiefWorkspacesSummary: Sendable, Equatable {
    /// One workspace as the summary lists it.
    public struct Line: Sendable, Equatable {
        /// The window's ref (`window:N`), nil when unknown.
        public var windowRef: String?
        /// The workspace's ref as the `cmux` CLI accepts it (`workspace:N`).
        public var ref: String
        /// The name the sidebar shows.
        public var title: String
        /// The focused terminal's directory, nil when unknown.
        public var directory: String?
        /// One word for its agents (`working`, `needs input`, `done`, `idle`), nil when it has none.
        public var agentState: String?
        /// True for the workspace selected in its window.
        public var isSelected: Bool

        /// Creates a line.
        public init(windowRef: String?, ref: String, title: String, directory: String?, agentState: String?,
                    isSelected: Bool) {
            self.windowRef = windowRef
            self.ref = ref
            self.title = title
            self.directory = directory
            self.agentState = agentState
            self.isSelected = isSelected
        }
    }

    /// The most workspaces listed.
    public static let limit = 30

    /// Every workspace, windows in order, sidebar order within each.
    public var lines: [Line]
    /// Abbreviated to `~` in directories.
    public var homeDirectory: String

    /// Creates a summary.
    ///
    /// - Parameters:
    ///   - lines: Every workspace, windows in order, sidebar order within each.
    ///   - homeDirectory: Abbreviated to `~` in directories.
    public init(lines: [Line], homeDirectory: String = NSHomeDirectory()) {
        self.lines = lines
        self.homeDirectory = homeDirectory
    }

    /// The section's body, nil when there are no workspaces.
    public func render() -> String? {
        let limit = Self.limit
        guard !lines.isEmpty else { return nil }
        let multipleWindows = Set(lines.compactMap(\.windowRef)).count > 1
        var out = lines.prefix(limit).map { line -> String in
            var fields = [line.ref]
            if multipleWindows, let window = line.windowRef { fields.append(window) }
            if let directory = line.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
                fields.append(Self.abbreviate(directory, home: homeDirectory))
            }
            if let state = line.agentState { fields.append("agent: \(state)") }
            if line.isSelected { fields.append("selected") }
            let title = ChiefMemory.normalize(line.title)
            return "- \"\(title.isEmpty ? "Untitled" : title)\" (\(fields.joined(separator: ", ")))"
        }
        if lines.count > limit {
            out.append("- (\(lines.count - limit) more workspaces not shown)")
        }
        out.append("For the current state run `cmux tree --all --json`.")
        return out.joined(separator: "\n")
    }

    /// `path` with the home directory written as `~`.
    static func abbreviate(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
