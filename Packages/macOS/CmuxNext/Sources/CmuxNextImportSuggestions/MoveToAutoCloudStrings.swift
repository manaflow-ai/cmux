import Foundation

/// Move this Mac to AutoCloud's preview and toasts (table `ImportSuggestions`). Counts are
/// formatted for the person's locale before they go into the text.
public nonisolated struct MoveToAutoCloudStrings: Sendable {
    public init() {}

    public static var previewTitle: String {
        String(localized: "moveToAutoCloud.preview.title", defaultValue: "Move these projects to AutoCloud?", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var previewButton: String {
        String(localized: "moveToAutoCloud.preview.button", defaultValue: "Move", table: "ImportSuggestions", bundle: .localizedModule)
    }
    /// Followed by one line per project's machine name.
    public static func projects(_ count: Int) -> String {
        format(String(localized: "moveToAutoCloud.preview.projects", defaultValue: "Projects, each on its own cloud machine: %@",
                      table: "ImportSuggestions", bundle: .localizedModule), count)
    }
    public static func carry(_ count: Int) -> String {
        format(String(localized: "moveToAutoCloud.preview.carry", defaultValue: "Settings that come along (shell, git, editor, agents): %@",
                      table: "ImportSuggestions", bundle: .localizedModule), count)
    }
    public static func unsupported(_ count: Int) -> String {
        format(String(localized: "moveToAutoCloud.preview.unsupported", defaultValue: "Left on this Mac: %@",
                      table: "ImportSuggestions", bundle: .localizedModule), count)
    }
    public static var unchanged: String {
        String(localized: "moveToAutoCloud.preview.unchanged",
               defaultValue: "Nothing on this Mac changes. Projects already moved aren’t moved twice.", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var moved: String {
        String(localized: "moveToAutoCloud.toast.moved", defaultValue: "Your projects are moving to AutoCloud.", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var nothing: String {
        String(localized: "moveToAutoCloud.toast.nothing", defaultValue: "No projects to move.", table: "ImportSuggestions", bundle: .localizedModule)
    }
    public static var failed: String {
        String(localized: "moveToAutoCloud.toast.failed", defaultValue: "Couldn’t move your projects to AutoCloud.", table: "ImportSuggestions", bundle: .localizedModule)
    }

    private static func format(_ template: String, _ count: Int) -> String {
        String(format: template, count.formatted(.number))
    }
}
