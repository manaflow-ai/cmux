/// The localized, user-facing strings rendered by the file-preview PDF sidebar
/// chrome menu (``FilePreviewPDFSidebarChromeView``).
///
/// Resolved app-side (where `String(localized:)` binds to the app bundle, which
/// owns the `filePreview.pdf.*` catalog keys) and injected into the package
/// view. Resolving them app-side is deliberate: a package calling
/// `String(localized:)` binds to the *package* bundle, which holds none of these
/// catalog entries, so every non-English localization would silently fall back
/// to the English `defaultValue`. Passing the already-resolved values keeps the
/// menu byte-identical in every locale after the move.
public struct FilePreviewPDFSidebarChromeStrings: Sendable, Equatable {
    /// Accessibility/label text for the sidebar options control (`filePreview.pdf.sidebarOptions`).
    public let sidebarOptions: String
    /// Toggle title shown while the sidebar is visible (`filePreview.pdf.hideSidebar`).
    public let hideSidebar: String
    /// Toggle title shown while the sidebar is hidden (`filePreview.pdf.showSidebar`).
    public let showSidebar: String
    /// Title of the thumbnails sidebar item (`filePreview.pdf.thumbnails`).
    public let thumbnails: String
    /// Title of the table-of-contents sidebar item (`filePreview.pdf.tableOfContents`).
    public let tableOfContents: String
    /// Title of the continuous-scroll display item (`filePreview.pdf.continuousScroll`).
    public let continuousScroll: String
    /// Title of the single-page display item (`filePreview.pdf.singlePage`).
    public let singlePage: String
    /// Title of the two-pages display item (`filePreview.pdf.twoPages`).
    public let twoPages: String

    /// Creates the PDF sidebar chrome string bundle.
    public init(
        sidebarOptions: String,
        hideSidebar: String,
        showSidebar: String,
        thumbnails: String,
        tableOfContents: String,
        continuousScroll: String,
        singlePage: String,
        twoPages: String
    ) {
        self.sidebarOptions = sidebarOptions
        self.hideSidebar = hideSidebar
        self.showSidebar = showSidebar
        self.thumbnails = thumbnails
        self.tableOfContents = tableOfContents
        self.continuousScroll = continuousScroll
        self.singlePage = singlePage
        self.twoPages = twoPages
    }
}
