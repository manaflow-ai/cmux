#if os(iOS)
import CmuxAgentChat
import CmuxMobileSupport
import CmuxMobileToast
import Observation
import UIKit

/// Native navigation destination for one artifact and its swipe-adjacent files.
@MainActor
public final class ChatArtifactViewerController: UIViewController, UIDocumentPickerDelegate {
    private let scope: ChatArtifactViewerScope
    private let loader: ChatArtifactLoader
    private let toasts: ToastCenter
    private let onDone: @MainActor () -> Void
    private let model: ChatArtifactViewerPagerModel
    private let pageController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal
    )
    private let pageCoordinator = ChatArtifactPageViewControllerCoordinator()

    private var observationGeneration = 0
    private var zoomedPath: String?
    private var presentedFileAction: ChatArtifactFileActionPresentation?
    private var isPresentingFileActionError = false

    /// Creates a native artifact viewer.
    public init(
        path: String,
        scope: ChatArtifactViewerScope = .chat,
        swipeOrder: ChatArtifactGallerySwipeOrder = ChatArtifactGallerySwipeOrder(items: []),
        loader: ChatArtifactLoader,
        toastCenter: ToastCenter,
        onDone: @escaping @MainActor () -> Void
    ) {
        self.scope = scope
        self.loader = loader
        self.toasts = toastCenter
        self.onDone = onDone
        model = ChatArtifactViewerPagerModel(
            initialPath: path,
            swipeOrder: swipeOrder,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "ChatArtifactViewer"

        addChild(pageController)
        pageController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageController.view)
        NSLayoutConstraint.activate([
            pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pageController.didMove(toParent: self)
        pageController.view.backgroundColor = .systemBackground
        pageController.view.clipsToBounds = true
        pageController.dataSource = pageCoordinator
        pageController.delegate = pageCoordinator
        pageCoordinator.attach(pageController)
        beginObservation()
    }

    public func update(
        path: String? = nil,
        swipeOrder: ChatArtifactGallerySwipeOrder
    ) {
        model.update(initialPath: path, swipeOrder: swipeOrder)
    }

    private func beginObservation() {
        observationGeneration &+= 1
        observeModel(generation: observationGeneration)
    }

    private func observeModel(generation: Int) {
        let state = withObservationTracking {
            (
                snapshot: model.toolbarSnapshot,
                pages: model.pageModels,
                usesPaging: model.usesPaging,
                selectedPath: model.selectedPath
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeModel(generation: generation)
            }
        }
        render(
            snapshot: state.snapshot,
            pages: state.pages,
            usesPaging: state.usesPaging,
            selectedPath: state.selectedPath
        )
    }

    private func render(
        snapshot: ChatArtifactViewerPageSnapshot,
        pages: [ChatArtifactViewerPageModel],
        usesPaging: Bool,
        selectedPath: String
    ) {
        title = snapshot.displayName
        navigationItem.largeTitleDisplayMode = .never
        configureToolbar(snapshot: snapshot)
        pageCoordinator.update(
            pages: pages.map(pageDescriptor),
            selectedPath: selectedPath,
            onSelectionChanged: { [weak self] in self?.model.select(path: $0) },
            isPagingEnabled: usesPaging && zoomedPath == nil
        )
        presentPreparedFileActionIfNeeded(snapshot.fileActionState.presentation)
        presentFileActionErrorIfNeeded(snapshot.fileActionState.showsError)
    }

    private func pageDescriptor(
        model pageModel: ChatArtifactViewerPageModel
    ) -> ChatArtifactViewerPageDescriptor {
        ChatArtifactViewerPageDescriptor(
            model: pageModel,
            scope: scope,
            loader: loader,
            onImageMinimumZoomChanged: { [weak self] path, isAtMinimum in
                guard let self else { return }
                if isAtMinimum {
                    if self.zoomedPath == path { self.zoomedPath = nil }
                } else {
                    self.zoomedPath = path
                }
                self.refreshPagingState()
            },
            onImageAction: { [weak self] action, snapshot in
                self?.performFileAction(action, snapshot: snapshot)
            },
            onDone: onDone
        )
    }

    private func refreshPagingState() {
        pageCoordinator.update(
            pages: model.pageModels.map(pageDescriptor),
            selectedPath: model.selectedPath,
            onSelectionChanged: { [weak self] in self?.model.select(path: $0) },
            isPagingEnabled: model.usesPaging && zoomedPath == nil
        )
    }

    private func configureToolbar(snapshot: ChatArtifactViewerPageSnapshot) {
        let done = UIBarButtonItem(
            title: String(
                localized: "chat.artifact.done",
                defaultValue: "Done",
                bundle: .module
            ),
            style: .done,
            target: self,
            action: #selector(donePressed)
        )
        done.accessibilityIdentifier = "ChatArtifactDoneButton"
        guard snapshot.hasViewerActions else {
            navigationItem.rightBarButtonItems = [done]
            return
        }

        let actions = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: actionsMenu(snapshot: snapshot)
        )
        actions.accessibilityLabel = String(
            localized: "chat.artifact.viewer.actions",
            defaultValue: "Viewer actions",
            bundle: .module
        )
        actions.accessibilityIdentifier = "ChatArtifactViewerActions"
        actions.isEnabled = !snapshot.fileActionState.isRunning
        navigationItem.rightBarButtonItems = [done, actions]
    }

    private func actionsMenu(snapshot: ChatArtifactViewerPageSnapshot) -> UIMenu {
        var groups: [UIMenuElement] = []
        if snapshot.hasFileActions {
            let policy = ChatArtifactActionVisibilityPolicy(
                viewerHasFileActions: snapshot.hasFileActions,
                isTextFile: snapshot.isTextFile,
                isImage: snapshot.isImage
            )
            groups.append(UIMenu(
                options: .displayInline,
                children: policy.actions.map { action in
                    UIAction(
                        title: action.localizedTitle,
                        image: UIImage(systemName: action.systemImage),
                        attributes: action == .copyContents && !snapshot.canCopyContents
                            ? .disabled
                            : []
                    ) { [weak self] _ in
                        self?.performFileAction(action, snapshot: snapshot)
                    }
                }
            ))
        }
        if snapshot.shouldShowTextJumpControls {
            groups.append(UIMenu(
                options: .displayInline,
                children: textActions(snapshot: snapshot)
            ))
        }
        if snapshot.state == .markdown,
           snapshot.markdownPresentation.isRenderedAvailable {
            groups.append(UIMenu(
                title: String(
                    localized: "chat.artifact.markdown.view",
                    defaultValue: "Markdown view",
                    bundle: .module
                ),
                options: .displayInline,
                children: [
                    markdownAction(
                        title: String(
                            localized: "chat.artifact.markdown.raw",
                            defaultValue: "Raw",
                            bundle: .module
                        ),
                        mode: .raw,
                        snapshot: snapshot
                    ),
                    markdownAction(
                        title: String(
                            localized: "chat.artifact.markdown.rendered",
                            defaultValue: "Rendered",
                            bundle: .module
                        ),
                        mode: .rendered,
                        snapshot: snapshot
                    ),
                ]
            ))
        }
        return UIMenu(children: groups)
    }

    private func textActions(snapshot: ChatArtifactViewerPageSnapshot) -> [UIAction] {
        [
            UIAction(
                title: String(
                    localized: "chat.artifact.search.title",
                    defaultValue: "Search",
                    bundle: .module
                ),
                image: UIImage(systemName: "magnifyingglass")
            ) { [weak self] _ in self?.model.toggleSearch(for: snapshot.path) },
            UIAction(
                title: String(
                    localized: "chat.artifact.line.goto",
                    defaultValue: "Go to line",
                    bundle: .module
                ),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            ) { [weak self] _ in self?.model.toggleGoToLine(for: snapshot.path) },
            UIAction(
                title: String(
                    localized: "chat.artifact.jump.top",
                    defaultValue: "Top",
                    bundle: .module
                ),
                image: UIImage(systemName: "arrow.up.to.line")
            ) { [weak self] _ in self?.model.requestTop(for: snapshot.path) },
            UIAction(
                title: jumpToEndTitle(snapshot: snapshot),
                image: UIImage(systemName: "arrow.down.to.line")
            ) { [weak self] _ in self?.model.requestBottom(for: snapshot.path) },
            UIAction(
                title: String(
                    localized: "chat.artifact.line.numbers",
                    defaultValue: "Line numbers",
                    bundle: .module
                ),
                image: UIImage(systemName: "number"),
                state: snapshot.showsLineNumbers ? .on : .off
            ) { [weak self] _ in self?.model.toggleLineNumbers(for: snapshot.path) },
            UIAction(
                title: String(
                    localized: "chat.artifact.wrap",
                    defaultValue: "Word wrap",
                    bundle: .module
                ),
                image: UIImage(systemName: "text.justify.left"),
                state: snapshot.wrapsLines ? .on : .off
            ) { [weak self] _ in self?.model.toggleWordWrap(for: snapshot.path) },
        ]
    }

    private func markdownAction(
        title: String,
        mode: ChatArtifactMarkdownMode,
        snapshot: ChatArtifactViewerPageSnapshot
    ) -> UIAction {
        UIAction(
            title: title,
            state: snapshot.markdownPresentation.mode == mode ? .on : .off
        ) { [weak self] _ in
            self?.model.selectMarkdownMode(for: snapshot.path, mode)
        }
    }

    private func jumpToEndTitle(snapshot: ChatArtifactViewerPageSnapshot) -> String {
        switch ChatArtifactTextEndJumpTarget(reachedEOF: snapshot.textReachedEOF) {
        case .end:
            String(
                localized: "chat.artifact.jump.end",
                defaultValue: "End",
                bundle: .module
            )
        case .latest:
            String(
                localized: "chat.artifact.jump.latest",
                defaultValue: "Latest",
                bundle: .module
            )
        }
    }

    private func performFileAction(
        _ action: ChatArtifactAction,
        snapshot: ChatArtifactViewerPageSnapshot
    ) {
        switch action {
        case .share:
            Task { await model.prepareShare(for: snapshot.path, loader: loader) }
        case .save:
            Task { await model.prepareSave(for: snapshot.path, loader: loader) }
        case .copyImage:
            guard case .image(let data) = snapshot.state else { return }
            UIPasteboard.general.image = UIImage(data: data)
            toasts.present(.copied())
        case .copyContents:
            UIPasteboard.general.string = snapshot.renderedText
            toasts.present(.copied())
        case .copyPath:
            UIPasteboard.general.string = snapshot.path
            toasts.present(.copied(L10n.string(
                "mobile.toast.pathCopied",
                defaultValue: "Path copied"
            )))
        }
    }

    private func presentPreparedFileActionIfNeeded(
        _ presentation: ChatArtifactFileActionPresentation?
    ) {
        guard let presentation,
              presentedFileAction?.id != presentation.id,
              presentedViewController == nil else { return }
        presentedFileAction = presentation
        switch presentation {
        case .share(let fileURL):
            let controller = UIActivityViewController(
                activityItems: [fileURL],
                applicationActivities: nil
            )
            controller.popoverPresentationController?.barButtonItem =
                navigationItem.rightBarButtonItems?.last
            controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
                Task { @MainActor [weak self] in self?.finishFileAction(presentation) }
            }
            present(controller, animated: true)
        case .save(let fileURL):
            let controller = UIDocumentPickerViewController(
                forExporting: [fileURL],
                asCopy: true
            )
            controller.delegate = self
            present(controller, animated: true)
        }
    }

    private func presentFileActionErrorIfNeeded(_ showsError: Bool) {
        guard showsError,
              !isPresentingFileActionError,
              presentedViewController == nil else { return }
        isPresentingFileActionError = true
        let alert = UIAlertController(
            title: String(
                localized: "chat.artifact.action_failed.title",
                defaultValue: "Couldn't complete action",
                bundle: .module
            ),
            message: String(
                localized: "chat.artifact.action_failed.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(
                localized: "chat.artifact.ok",
                defaultValue: "OK",
                bundle: .module
            ),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            self.isPresentingFileActionError = false
            self.model.setShowsFileActionError(false, for: self.model.selectedPath)
        })
        present(alert, animated: true)
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishCurrentFileAction()
    }

    public func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        finishCurrentFileAction()
    }

    private func finishCurrentFileAction() {
        guard let presentedFileAction else { return }
        finishFileAction(presentedFileAction)
    }

    private func finishFileAction(_ presentation: ChatArtifactFileActionPresentation) {
        guard presentedFileAction?.id == presentation.id else { return }
        presentedFileAction = nil
        model.setFileActionPresentation(nil, for: model.selectedPath)
        Task {
            await ChatArtifactFileActionStore.applicationDefault.remove(presentation.fileURL)
        }
    }

    @objc private func donePressed() {
        onDone()
    }
}
#endif
