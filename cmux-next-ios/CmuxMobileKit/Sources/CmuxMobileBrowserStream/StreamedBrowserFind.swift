#if os(iOS)
import UIKit

/// Find in page on a streamed page (the Mac's Find…, Find Next, Find Previous; Safari's
/// Find on Page): the system find bar (`UIFindInteraction`, Apple HIG "Searching") over
/// the page. The page runs on the Mac, so the Mac's browser finds and highlights the
/// matches (`rb.find`) and reports their count and the active one (`rb.find.result`); the
/// bar's arrows and Return step through them, its count reads "2 of 5", and Done ends the
/// search (`rb.find.stop`).
@MainActor
final class StreamedBrowserFindController: NSObject, @MainActor UIFindInteractionDelegate, StreamedBrowserFindBar {
    private let model: StreamedBrowserModel
    private var interaction: UIFindInteraction?
    /// The bar closed: give the keyboard back to the page when it had it.
    var ended: (_ restoreFocus: Bool) -> Void = { _ in }
    /// Whether the page had the keyboard when the bar opened (asked when it opens).
    var pageHasFocus: () -> Bool = { false }
    private var restoreFocus = false

    init(model: StreamedBrowserModel) {
        self.model = model
        super.init()
    }

    /// The find bar is up.
    var isActive: Bool { interaction?.isFindNavigatorVisible == true }

    func install(in view: UIView) {
        let interaction = UIFindInteraction(sessionDelegate: self)
        view.addInteraction(interaction)
        self.interaction = interaction
        model.findBar = self
    }

    /// Find… (the page menu, Cmd-F): shows the bar with the last query.
    func present() {
        guard let interaction else { return }
        if !interaction.isFindNavigatorVisible { restoreFocus = pageHasFocus() }
        interaction.presentFindNavigator(showingReplace: false)
    }

    /// Find Next / Find Previous (Cmd-G, Shift-Cmd-G): opens the bar first when it is closed.
    func step(forward: Bool) {
        guard let interaction else { return }
        guard interaction.isFindNavigatorVisible else { return present() }
        if forward { interaction.findNext() } else { interaction.findPrevious() }
    }

    func resultsChanged() {
        interaction?.updateResultCount()
    }

    // MARK: UIFindInteractionDelegate

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        StreamedBrowserFindSession(model: model)
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        model.stopFind()
        let restore = restoreFocus
        restoreFocus = false
        ended(restore)
    }
}

/// The find bar's session: the bar asks it to search and step, and reads the page's count.
@MainActor
private final class StreamedBrowserFindSession: UIFindSession {
    private weak var model: StreamedBrowserModel?

    init(model: StreamedBrowserModel) {
        self.model = model
        super.init()
    }

    override var resultCount: Int { model?.findResult?.matches ?? 0 }

    override var highlightedResultIndex: Int { model?.findResult?.activeIndex ?? NSNotFound }

    override var supportsReplacement: Bool { false }

    override func performSearch(query: String, options: UITextSearchOptions?) {
        model?.find(query)
    }

    override func highlightNextResult(in direction: UITextStorageDirection) {
        model?.findNext(forward: direction == .forward)
    }

    override func invalidateFoundResults() {
        model?.clearFindResult()
    }
}
#endif
