public import Foundation

/// The live-workspace title state ``WorkspaceTitleModel`` reaches back into.
///
/// ``WorkspaceTitleModel`` owns the custom-title / custom-description
/// state-transition logic the legacy `Workspace` god object kept inline
/// (`setCustomTitle`, `setCustomDescription`, `applyProcessTitle`, the
/// `hasCustomTitle` / `effectiveCustomTitleSource` / `hasCustomDescription`
/// derivations, and the `normalizedCustomDescription` normalizer). The state
/// those bodies read and write is the workspace's `@Published` title vocabulary
/// (`title`, `customTitle`, `customTitleSource`, `customDescription`,
/// `processTitle`), whose `didSet` / `objectWillChange` emissions drive the UI,
/// so it is irreducibly app-coupled: the model reaches each property through
/// this seam, the app target's `Workspace` conforms, and it is injected via
/// ``WorkspaceTitleModel/attach(host:)``.
///
/// Every member mirrors a read or write the legacy method bodies made on `self`
/// (`title`, `customTitle`, `customTitleSource`, `customDescription`,
/// `processTitle`), plus the two DEBUG `cmuxDebugLog` lines whose
/// workspace-id prefix keeps them app-side, so the move is byte-faithful.
@MainActor
public protocol WorkspaceTitleHosting: AnyObject {
    /// The workspace title shown in the tab bar (legacy `Workspace.title`). The
    /// setter is the `@Published` property the title transitions assign exactly
    /// as the legacy bodies did.
    var workspaceTitleText: String { get set }

    /// The user/auto custom title, or `nil` when none is set (legacy
    /// `Workspace.customTitle`).
    var workspaceTitleCustomTitle: String? { get set }

    /// The provenance of the current custom title (legacy
    /// `Workspace.customTitleSource`).
    var workspaceTitleCustomTitleSource: CustomTitleSource? { get set }

    /// The custom workspace description (legacy `Workspace.customDescription`).
    var workspaceTitleCustomDescription: String? { get set }

    /// The latest process-reported title (legacy `Workspace.processTitle`).
    var workspaceTitleProcessTitle: String { get set }

    /// Emits the DEBUG `workspace.title.applyProcess` log line the legacy
    /// `applyProcessTitle` wrote before assigning a new process-derived title.
    /// A no-op in release builds; kept on the host so the `cmuxDebugLog` sink
    /// and its workspace-id prefix stay app-side.
    func workspaceTitleLogApplyProcess(from previousTitle: String, to title: String)

    /// Emits the DEBUG `workspace.customDescription.update` log line the legacy
    /// `setCustomDescription` wrote. A no-op in release builds; kept on the host
    /// so the `cmuxDebugLog` sink and its workspace-id prefix stay app-side.
    func workspaceTitleLogCustomDescriptionUpdate(
        input: String?,
        normalized: String?
    )
}
