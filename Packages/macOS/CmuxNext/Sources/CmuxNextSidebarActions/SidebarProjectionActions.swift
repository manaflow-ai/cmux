public import CmuxNextActions
import CmuxNextDesign
public import CmuxNextSettings

/// The way back from every sidebar hide (CMUX-383 slice 2; Leo, Linear CMUX-383: "Sidebar
/// customization (look at BB and Herder)"; 2026-11-15: "opt-in settings land once styled well with
/// no soft-lock"). Both are palette rows and buttons on Settings > Sidebar, and both write the
/// same `sidebar.sections` / `sidebar.workspaces` keys a hand edit of cmux-next.json does, through
/// Rust's `sidebar_projection_edit`:
///
/// - `sidebar.showHidden`: every hidden section and workspace shows again; order and groups stay.
/// - `sidebar.resetLayout`: every projection override goes (hides, section order, workspace
///   groups and order), so the sidebar document's own placement shows again.
///
/// The watcher applies the write live; no restart, no Apply button.
@MainActor
public struct SidebarProjectionActions {
    public static let showHidden: ActionID = "sidebar.showHidden"
    public static let resetLayout: ActionID = "sidebar.resetLayout"

    private let settings: @MainActor () -> SettingsController?

    public init(settings: @escaping @MainActor () -> SettingsController?) {
        self.settings = settings
    }

    public func bind(into registry: ActionRegistry) {
        bind(Self.showHidden, edit: .showAll, into: registry)
        bind(Self.resetLayout, edit: .reset, into: registry)
    }

    private func bind(_ id: ActionID, edit: SidebarProjectionEdit, into registry: ActionRegistry) {
        let settings = settings
        registry.bindEffect(id, unavailable: { nil }) { _ in
            guard let controller = settings() else { return .done }
            return .applied(result: {
                do {
                    try await controller.editSidebarProjection(edit)
                    return .success([:])
                } catch {
                    return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error)))
                }
            })
        }
    }
}
