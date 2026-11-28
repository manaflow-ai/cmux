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
    /// After the project list: those an earlier run moved, which this one skips.
    public static func already(_ count: Int) -> String {
        format(String(localized: "moveToAutoCloud.preview.already", defaultValue: "Already on AutoCloud from an earlier move, skipped: %@",
                      table: "ImportSuggestions", bundle: .localizedModule), count)
    }
    /// Apply finished: every project it was asked to move has its machine.
    public static func moved(_ count: Int) -> String {
        format(String(localized: "moveToAutoCloud.toast.movedCount", defaultValue: "Moved to AutoCloud: %@ projects.",
                      table: "ImportSuggestions", bundle: .localizedModule), count)
    }
    /// Nothing left to move: an earlier run moved them all.
    public static func allMoved(_ count: Int) -> String {
        format(String(localized: "moveToAutoCloud.toast.allMoved", defaultValue: "Already on AutoCloud: %@ projects. Nothing left to move.",
                      table: "ImportSuggestions", bundle: .localizedModule), count)
    }
    /// Apply ended with some projects still not moved; the card offers Try Again.
    public static func unfinished(moved: Int, left: Int) -> String {
        String(format: String(localized: "moveToAutoCloud.toast.unfinished",
                              defaultValue: "Moved to AutoCloud: %1$@ projects. Not moved yet: %2$@. Try Again moves the rest.",
                              table: "ImportSuggestions", bundle: .localizedModule),
               moved.formatted(.number), left.formatted(.number))
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
