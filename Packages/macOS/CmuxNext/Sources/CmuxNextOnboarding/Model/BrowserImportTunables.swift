public import CmuxNextDesign

/// Debug Settings of Import from Browser (DEV and NIGHTLY; Release and RC
/// keep the defaults).
public nonisolated struct BrowserImportTunables {
    public nonisolated init() {}
    public static let section = TunableSection(id: "browserImport", title: "Browser Import", symbol: "square.and.arrow.down", order: 47)

    /// On (the default): a browser's profiles are read only after the person
    /// picked its data folder in the open panel (a security-scoped bookmark
    /// per browser). Off: the earlier behavior, every browser's folder is
    /// read on Find Browsers.
    public static let folderGrant = Tunable<Bool>.toggle(
        "browserImport.folderGrant", section, "Ask for each browser's folder",
        help: "Import from Browser reads a browser's profiles only after you pick its folder in the open panel. Off reads every browser's folder on Find Browsers.",
        default: true, code: "BrowserImportTunables.folderGrant")

    /// On (the default): Settings › Import shows cards for what this Mac has that cmux can bring
    /// over (CmuxNextImportCards). Off: no cards and no scan. Home and New Tab never show them.
    public static let suggestionCards = Tunable<Bool>.toggle(
        "browserImport.suggestionCards", section, "Show import suggestion cards",
        help: "Settings › Import suggests what to bring over from other browsers, agents and terminals on this Mac. Off hides the cards and stops the scan.",
        default: true, code: "BrowserImportTunables.suggestionCards")

    public static var all: [TunableDescriptor] { [folderGrant.descriptor, suggestionCards.descriptor] }
}
