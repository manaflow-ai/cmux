/// Localized copy for ``ExtensionSidebarEmptyStateView`` resolved by the app
/// composition root.
///
/// Every string is resolved with `String(localized:)` in the app target so the
/// app bundle's localized catalog (including Japanese) is used; resolving them
/// inside this package bundle would miss the catalog and silently drop every
/// non-English translation. The empty state branches on the live availability
/// counts, so all candidate strings are supplied and the view picks which to
/// show.
public struct ExtensionSidebarEmptyStateStrings: Sendable {
    /// Title shown when more than one extension is enabled and the user must
    /// choose which one replaces the sidebar.
    public let chooseTitle: String
    /// Title shown when no sidebar extension is enabled.
    public let emptyTitle: String
    /// Detail shown alongside ``chooseTitle``.
    public let chooseDetail: String
    /// Detail shown alongside ``emptyTitle``.
    public let emptyDetail: String
    /// Availability detail shown when an installed extension is unapproved.
    public let unapprovedDetail: String
    /// Availability detail shown when an installed extension is disabled.
    public let disabledDetail: String
    /// Label for the extension-chooser menu.
    public let chooseAction: String
    /// Label for the manage-extensions action.
    public let manage: String
    /// Label for the use-default-sidebar action.
    public let useDefault: String

    public init(
        chooseTitle: String,
        emptyTitle: String,
        chooseDetail: String,
        emptyDetail: String,
        unapprovedDetail: String,
        disabledDetail: String,
        chooseAction: String,
        manage: String,
        useDefault: String
    ) {
        self.chooseTitle = chooseTitle
        self.emptyTitle = emptyTitle
        self.chooseDetail = chooseDetail
        self.emptyDetail = emptyDetail
        self.unapprovedDetail = unapprovedDetail
        self.disabledDetail = disabledDetail
        self.chooseAction = chooseAction
        self.manage = manage
        self.useDefault = useDefault
    }
}
