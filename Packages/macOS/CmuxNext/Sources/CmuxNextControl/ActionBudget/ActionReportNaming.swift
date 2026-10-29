public import CmuxNextActions

/// The id an action's runs carry in the opt-in nightly report: the catalog id for a catalog action,
/// one fixed id per kind for every other (cmux.json commands are `custom`, anything else bound
/// outside the catalog is `extension`), because those ids carry the person's own text (a command
/// named after a client or a folder). The Debug HUD and the local Debug log keep the real id.
public struct ActionReportNaming: Sendable {
    /// The report id of every cmux.json command (`cmuxConfig.<name>`).
    public static let custom = "custom"
    /// The report id of every other action bound outside the catalog.
    public static let other = "extension"
    /// The id prefix cmux.json commands are bound under (`ConfigActionsController`).
    static let customPrefix = "cmuxConfig."

    private let catalog: Set<String>

    /// - Parameter catalog: The catalog's action ids (`ActionCatalog.all`), the only ids reported as is.
    public init(catalog: Set<String>) {
        self.catalog = catalog
    }

    /// The id `id`'s runs are reported under.
    public func reportID(for id: ActionID) -> String {
        if id.rawValue.hasPrefix(Self.customPrefix) { return Self.custom }
        return catalog.contains(id.rawValue) ? id.rawValue : Self.other
    }
}
