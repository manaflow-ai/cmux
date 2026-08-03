#if os(iOS)
import CmuxAgentChat
import Observation
import UIKit

/// Native artifact preview for embedding inside another controller's content area.
@MainActor
public final class ChatArtifactInlineViewController: UIViewController, UIDocumentPickerDelegate {
    public var onActionDescriptorChanged: @MainActor (ChatArtifactInlineActionDescriptor?) -> Void = { _ in }

    private let loader: ChatArtifactLoader
    private let actionHost: ChatArtifactInlineActionHost?
    private let pageModel: ChatArtifactViewerPageModel
    private let pageController: ChatArtifactViewerPageController
    private var observationGeneration = 0
    private var actionRegistrationID: Int?
    private var actionDescriptor: ChatArtifactInlineActionDescriptor?
    private var presentedFileAction: ChatArtifactFileActionPresentation?
    private var isPresentingFileActionError = false

    public init(
        path: String,
        loader: ChatArtifactLoader,
        actionHost: ChatArtifactInlineActionHost? = nil
    ) {
        self.loader = loader
        self.actionHost = actionHost
        let model = ChatArtifactViewerPageModel(
            path: path,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        )
        pageModel = model
        pageController = ChatArtifactViewerPageController(descriptor: ChatArtifactViewerPageDescriptor(
            model: model,
            scope: .terminal,
            loader: loader,
            onImageMinimumZoomChanged: { _, _ in },
            onImageAction: { _, _ in },
            onDone: {}
        ))
        super.init(nibName: nil, bundle: nil)
        pageController.update(descriptor: pageDescriptor())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        view.accessibilityIdentifier = "ChatArtifactInlineViewer"
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
        beginObservation()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clearActionRegistration()
    }

    private func pageDescriptor() -> ChatArtifactViewerPageDescriptor {
        ChatArtifactViewerPageDescriptor(
            model: pageModel,
            scope: .terminal,
            loader: loader,
            onImageMinimumZoomChanged: { _, _ in },
            onImageAction: { [weak self] action, _ in self?.perform(action) },
            onDone: {}
        )
    }

    private func beginObservation() {
        observationGeneration &+= 1
        observeModel(generation: observationGeneration)
    }

    private func observeModel(generation: Int) {
        let snapshot = withObservationTracking {
            pageModel.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeModel(generation: generation)
            }
        }
        render(snapshot)
    }

    private func render(_ snapshot: ChatArtifactViewerPageSnapshot) {
        pageController.update(descriptor: pageDescriptor())
        updateActionRegistration(snapshot: snapshot)
        presentPreparedFileActionIfNeeded(snapshot.fileActionState.presentation)
        presentFileActionErrorIfNeeded(snapshot.fileActionState.showsError)
    }

    private func updateActionRegistration(snapshot: ChatArtifactViewerPageSnapshot) {
        let policy = ChatArtifactActionVisibilityPolicy(inlineState: snapshot.state)
        let descriptor = policy.inlineStateIdentity.flatMap { identity in
            policy.actions.isEmpty ? nil : ChatArtifactInlineActionDescriptor(
                id: "\(snapshot.path)\u{0}\(identity)",
                actions: policy.actions,
                isRunning: snapshot.fileActionState.isRunning
            )
        }
        guard descriptor != actionDescriptor else { return }
        clearActionRegistration()
        actionDescriptor = descriptor
        onActionDescriptorChanged(descriptor)
        guard let actionHost, let descriptor else { return }
        actionRegistrationID = actionHost.register(descriptor: descriptor) { [weak self] action in
            self?.perform(action)
        }
    }

    private func clearActionRegistration() {
        if let actionRegistrationID {
            actionHost?.clear(registrationID: actionRegistrationID)
        }
        actionRegistrationID = nil
        actionDescriptor = nil
        onActionDescriptorChanged(nil)
    }

    private func perform(_ action: ChatArtifactAction) {
        switch action {
        case .share:
            Task { await pageModel.prepareShare(loader: loader) }
        case .save:
            Task { await pageModel.prepareSave(loader: loader) }
        case .copyImage:
            guard case .image(let data) = pageModel.snapshot.state else { return }
            UIPasteboard.general.image = UIImage(data: data)
        case .copyContents, .copyPath:
            break
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
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 1,
                height: 1
            )
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
            self?.isPresentingFileActionError = false
            self?.pageModel.setShowsFileActionError(false)
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
        pageModel.setFileActionPresentation(nil)
        Task {
            await ChatArtifactFileActionStore.applicationDefault.remove(presentation.fileURL)
        }
    }
}
#endif
