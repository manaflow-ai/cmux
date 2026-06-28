public import Foundation

/// Main-actor action closures the browser-profile popover rows invoke.
///
/// Each closure runs the app-side mutation (apply a profile selection, present
/// the create/rename prompts, open the import dialog). Keeping the side effects
/// behind closures lets the popover view live in this package while every panel
/// mutation and `@State` popover toggle stays on the app-side forwarder.
public struct BrowserProfilePopoverActions {
    /// Activate the profile with the given identifier.
    public var onSelectProfile: @MainActor (UUID) -> Void
    /// Present the create-new-profile prompt (the forwarder dismisses the popover).
    public var onCreateProfile: @MainActor () -> Void
    /// Present the rename-current-profile prompt (the forwarder dismisses the popover).
    public var onRenameProfile: @MainActor () -> Void
    /// Open the import-browser-data dialog from the profile menu.
    public var onOpenImportSettings: @MainActor () -> Void

    /// Creates the profile popover action bundle.
    public init(
        onSelectProfile: @escaping @MainActor (UUID) -> Void,
        onCreateProfile: @escaping @MainActor () -> Void,
        onRenameProfile: @escaping @MainActor () -> Void,
        onOpenImportSettings: @escaping @MainActor () -> Void
    ) {
        self.onSelectProfile = onSelectProfile
        self.onCreateProfile = onCreateProfile
        self.onRenameProfile = onRenameProfile
        self.onOpenImportSettings = onOpenImportSettings
    }
}
