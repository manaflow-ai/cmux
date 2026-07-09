public import Foundation

/// The Sendable projection of a freshly registered surface panel that
/// ``SurfaceCreationCoordinator`` carries from the app-target panel-registration
/// witness (``SurfaceCreationHosting/registerProjectPanel(projectURL:)``) into
/// the generic tab-creation witness
/// (``SurfaceCreationHosting/createSurfaceTab(descriptor:kind:inPane:)``).
///
/// The coordinator owns the create-tab orchestration (register the panel, create
/// the bonsplit tab, reorder, publish, focus) but cannot name the app's panel
/// types (`ProjectPanel`, `MarkdownPanel`, …). The host registers the panel in
/// its registries and hands back this value snapshot, which carries exactly the
/// fields the legacy `Workspace` body fed into `bonsplitController.createTab`:
/// the panel identity, its display title and icon, and its dirty flag. The
/// coordinator then drives every subsequent live op by `id`.
public struct SurfaceTabDescriptor: Sendable {
    /// The registered panel's identity (`Panel.id`), the key the coordinator
    /// returns and the host maps back to its typed panel.
    public let id: UUID

    /// The panel's display title, written to the workspace `panelTitles` registry
    /// and passed to `bonsplitController.createTab(title:)`.
    public let displayTitle: String

    /// The panel's display icon (SF Symbol name), passed to
    /// `bonsplitController.createTab(icon:)`.
    public let displayIcon: String?

    /// Whether the new tab is created dirty, passed to
    /// `bonsplitController.createTab(isDirty:)`. Project surfaces register clean
    /// (`false`), matching the legacy literal.
    public let isDirty: Bool

    /// Creates a descriptor for a freshly registered surface panel.
    public init(id: UUID, displayTitle: String, displayIcon: String?, isDirty: Bool) {
        self.id = id
        self.displayTitle = displayTitle
        self.displayIcon = displayIcon
        self.isDirty = isDirty
    }
}
