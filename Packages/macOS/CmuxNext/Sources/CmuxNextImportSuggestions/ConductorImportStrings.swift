import Foundation

/// Import from Conductor's preview and toasts (table `ImportSuggestions`). Counts are
/// formatted for the person's locale before they go into the text.
public nonisolated struct ConductorImportStrings: Sendable {
    public init() {}

    public static var previewTitle: String {
        String(localized: "conductorImport.preview.title", defaultValue: "Import these Conductor workspaces?", table: "ImportSuggestions", bundle: .module)
    }
    public static var previewButton: String {
        String(localized: "conductorImport.preview.button", defaultValue: "Import", table: "ImportSuggestions", bundle: .module)
    }
    public static func projects(_ count: Int) -> String {
        format(String(localized: "conductorImport.preview.projects", defaultValue: "Projects: %@", table: "ImportSuggestions", bundle: .module), count)
    }
    public static func adopted(_ count: Int) -> String {
        format(String(localized: "conductorImport.preview.adopted", defaultValue: "Workspaces opened in place, in their own folders: %@",
                      table: "ImportSuggestions", bundle: .module), count)
    }
    public static func chats(_ count: Int) -> String {
        format(String(localized: "conductorImport.preview.chats", defaultValue: "Claude Code chats found in them: %@",
                      table: "ImportSuggestions", bundle: .module), count)
    }
    public static func recoverable(_ count: Int) -> String {
        format(String(localized: "conductorImport.preview.recoverable",
                      defaultValue: "Archived workspaces left out (their commits are still in the repository): %@",
                      table: "ImportSuggestions", bundle: .module), count)
    }
    public static func cleanup(_ count: Int) -> String {
        format(String(localized: "conductorImport.preview.cleanup", defaultValue: "Interrupted workspaces to replace (their terminals will end): %@",
                      table: "ImportSuggestions", bundle: .module), count)
    }
    /// `names`: the variables' names, never their values.
    public static func environment(_ names: String) -> String {
        String(format: String(localized: "conductorImport.preview.environment",
                              defaultValue: "Environment variables Conductor set, which you set yourself here: %@",
                              table: "ImportSuggestions", bundle: .module), names)
    }
    public static var archiveWarning: String {
        String(localized: "conductorImport.preview.archiveWarning",
               defaultValue: "Archiving one of these workspaces in Conductor deletes its folder, which cmux now uses. Archive it in cmux instead.",
               table: "ImportSuggestions", bundle: .module)
    }
    public static var deadline: String {
        String(localized: "conductorImport.preview.deadline",
               defaultValue: "Conductor Cloud becomes read-only on November 13 and shuts down on November 20.", table: "ImportSuggestions", bundle: .module)
    }
    public static var opened: String {
        String(localized: "conductorImport.toast.opened", defaultValue: "Your Conductor workspaces are open.", table: "ImportSuggestions", bundle: .module)
    }
    public static var allHere: String {
        String(localized: "conductorImport.toast.allHere", defaultValue: "Every Conductor workspace is already open here.", table: "ImportSuggestions", bundle: .module)
    }
    public static var failed: String {
        String(localized: "conductorImport.toast.failed", defaultValue: "Couldn’t import from Conductor.", table: "ImportSuggestions", bundle: .module)
    }

    private static func format(_ template: String, _ count: Int) -> String {
        String(format: template, count.formatted(.number))
    }
}
