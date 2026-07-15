import CmuxAgentChat
import Foundation
import Observation

/// Retains one page owner per visible path while projecting a single selected toolbar state.
@Observable
@MainActor
final class ChatArtifactViewerPagerModel {
    private(set) var selectedPath: String
    private(set) var swipeOrder: ChatArtifactGallerySwipeOrder
    private let textPreferences: ChatArtifactTextPreferences
    @ObservationIgnored private var selectedPageModel: ChatArtifactViewerPageModel
    @ObservationIgnored
    private var pagesByPath: [String: ChatArtifactViewerPageModel] = [:]

    init(
        initialPath: String,
        swipeOrder: ChatArtifactGallerySwipeOrder,
        textPreferences: ChatArtifactTextPreferences
    ) {
        selectedPath = initialPath
        self.swipeOrder = swipeOrder
        self.textPreferences = textPreferences
        let initialPage = ChatArtifactViewerPageModel(
            path: initialPath,
            textPreferences: textPreferences
        )
        selectedPageModel = initialPage
        pagesByPath[initialPath] = initialPage
        reconcilePages()
    }

    var pageSnapshots: [ChatArtifactViewerPageSnapshot] {
        pagePaths.compactMap { pagesByPath[$0]?.snapshot }
    }

    var pageModels: [ChatArtifactViewerPageModel] {
        pagePaths.compactMap { pagesByPath[$0] }
    }

    var toolbarSnapshot: ChatArtifactViewerPageSnapshot {
        selectedPageModel.snapshot
    }

    var usesPaging: Bool {
        swipeOrder.count > 1 && swipeOrder.paths.contains(selectedPath)
    }

    func select(path: String) {
        guard path != selectedPath, swipeOrder.paths.contains(path) else { return }
        selectedPageModel = page(for: path)
        selectedPath = path
        reconcilePages()
    }

    func update(
        initialPath: String? = nil,
        swipeOrder: ChatArtifactGallerySwipeOrder
    ) {
        self.swipeOrder = swipeOrder
        if let initialPath, initialPath != selectedPath {
            selectedPageModel = page(for: initialPath)
            selectedPath = initialPath
        }
        reconcilePages()
    }

    func pageIdentity(for path: String) -> ObjectIdentifier? {
        pagesByPath[path].map(ObjectIdentifier.init)
    }

    func actions(
        for path: String,
        loader: ChatArtifactLoader,
        quickLookCanPreview: @escaping @MainActor (URL) -> Bool
    ) -> ChatArtifactViewerPageActions {
        let page = path == selectedPath
            ? selectedPageModel
            : pagesByPath[path]!
        return page.actions(
            loader: loader,
            quickLookCanPreview: quickLookCanPreview
        )
    }

    func toggleSearch() {
        selectedPage.toggleSearch()
    }

    func toggleGoToLine() {
        selectedPage.toggleGoToLine()
    }

    func requestTop() {
        selectedPage.requestTop()
    }

    func requestBottom() {
        selectedPage.requestBottom()
    }

    func toggleLineNumbers() {
        selectedPage.toggleLineNumbers()
    }

    func toggleWordWrap() {
        selectedPage.toggleWordWrap()
    }

    func selectMarkdownMode(_ mode: ChatArtifactMarkdownMode) {
        selectedPage.selectMarkdownMode(mode)
    }

    #if os(iOS)
    func prepareShare(loader: ChatArtifactLoader) async {
        let page = selectedPage
        await page.prepareShare(loader: loader)
    }

    func prepareSave(loader: ChatArtifactLoader) async {
        let page = selectedPage
        await page.prepareSave(loader: loader)
    }

    func setFileActionPresentation(
        _ presentation: ChatArtifactFileActionPresentation?,
        for path: String
    ) {
        pagesByPath[path]?.setFileActionPresentation(presentation)
    }

    func setShowsFileActionError(_ isPresented: Bool, for path: String) {
        pagesByPath[path]?.setShowsFileActionError(isPresented)
    }
    #endif

    private var selectedPage: ChatArtifactViewerPageModel {
        selectedPageModel
    }

    private var pagePaths: [String] {
        guard swipeOrder.paths.contains(selectedPath) else { return [selectedPath] }
        return swipeOrder.pageWindow(around: selectedPath).map(\.path)
    }

    private func page(for path: String) -> ChatArtifactViewerPageModel {
        if let page = pagesByPath[path] {
            return page
        }
        let page = ChatArtifactViewerPageModel(
            path: path,
            textPreferences: textPreferences
        )
        pagesByPath[path] = page
        return page
    }

    private func reconcilePages() {
        var nextPages: [String: ChatArtifactViewerPageModel] = [:]
        for path in pagePaths {
            nextPages[path] = page(for: path)
        }
        pagesByPath = nextPages
    }
}
