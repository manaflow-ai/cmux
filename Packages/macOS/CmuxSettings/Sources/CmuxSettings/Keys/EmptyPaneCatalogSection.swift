import Foundation

/// Settings under the dotted-id prefix `emptyPane.*`: what a pane with no
/// surfaces shows.
public struct EmptyPaneCatalogSection: SettingCatalogSection {
    /// Path to a text or ANSI art file shown in empty panes instead of the
    /// default icon and title, for example `~/.config/cmux/empty-pane.ans`.
    ///
    /// Empty (the default) keeps the standard empty pane. A leading `~` is
    /// expanded. A missing, unreadable or oversized file also falls back to
    /// the standard view.
    public let artFile = DefaultsKey<String>(
        id: "emptyPane.artFile",
        defaultValue: "",
        // Undotted: a dotted @AppStorage key re-evaluates its view on every
        // unrelated defaults write.
        userDefaultsKey: "emptyPaneArtFile"
    )

    public init() {}
}
