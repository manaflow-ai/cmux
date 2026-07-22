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

    func toggleSearch(for path: String) {
        pageModel(for: path)?.toggleSearch()
    }

    func toggleGoToLine(for path: String) {
        pageModel(for: path)?.toggleGoToLine()
    }

    func requestTop(for path: String) {
        pageModel(for: path)?.requestTop()
    }

    func requestBottom(for path: String) {
        pageModel(for: path)?.requestBottom()
    }

    func toggleLineNumbers(for path: String) {
        pageModel(for: path)?.toggleLineNumbers()
    }

    func toggleWordWrap(for path: String) {
        pageModel(for: path)?.toggleWordWrap()
    }

    func selectMarkdownMode(for path: String, _ mode: ChatArtifactMarkdownMode) {
        pageModel(for: path)?.selectMarkdownMode(mode)
    }

    #if os(iOS)
    func prepareShare(for path: String, loader: ChatArtifactLoader) async {
        guard let page = pageModel(for: path) else { return }
        await page.prepareShare(loader: loader)
    }

    func prepareSave(for path: String, loader: ChatArtifactLoader) async {
        guard let page = pageModel(for: path) else { return }
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

    private func pageModel(for path: String) -> ChatArtifactViewerPageModel? {
        path == selectedPath ? selectedPageModel : pagesByPath[path]
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
