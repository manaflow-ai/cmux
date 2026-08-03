#if os(iOS)
import AVKit
import CmuxAgentChat
import Observation
import QuickLook
import UIKit

/// Native controller for one observable artifact route and its cancellable load lifecycle.
@MainActor
final class ChatArtifactViewerPageController: UIViewController {
    private var descriptor: ChatArtifactViewerPageDescriptor
    private var observationGeneration = 0
    private var lifecycleTask: Task<Void, Never>?
    private var observedRetryGeneration: Int?
    private var contentIdentity: ContentIdentity?
    private var contentView: UIView?
    private var embeddedController: UIViewController?
    private var quickLookCoordinator: ChatArtifactQuickLookCoordinator?
    private var renderedImageData: Data?

    init(descriptor: ChatArtifactViewerPageDescriptor) {
        self.descriptor = descriptor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var path: String { descriptor.path }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        root.isOpaque = true
        root.clipsToBounds = true
        view = root
        beginObservation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLifecycleIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopLifecycle()
        descriptor.onImageMinimumZoomChanged(path, true)
    }

    func update(descriptor: ChatArtifactViewerPageDescriptor) {
        self.descriptor = descriptor
        guard isViewLoaded else { return }
        beginObservation()
    }

    private func beginObservation() {
        observationGeneration &+= 1
        observeModel(generation: observationGeneration)
    }

    private func observeModel(generation: Int) {
        let snapshot = withObservationTracking {
            descriptor.model.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeModel(generation: generation)
            }
        }
        render(snapshot)
    }

    private func render(_ snapshot: ChatArtifactViewerPageSnapshot) {
        if let observedRetryGeneration,
           observedRetryGeneration != snapshot.retryGeneration,
           viewIfLoaded?.window != nil {
            restartLifecycle()
        }
        observedRetryGeneration = snapshot.retryGeneration

        switch snapshot.state {
        case .loading:
            let loading = ensureLoadingView()
            loading.update(
                fetched: snapshot.fetchedBytes,
                total: snapshot.totalBytes
            )
        case .folder:
            _ = ensureFolderController(path: snapshot.path)
        case .image(let data):
            guard let image = image(for: data) else {
                installEmptyView(identity: .empty)
                return
            }
            let imageView: ChatArtifactZoomableImageNativeView
            if contentIdentity == .image,
               let existing = contentView as? ChatArtifactZoomableImageNativeView {
                imageView = existing
                imageView.update(
                    image: image,
                    onMinimumZoomChanged: imageMinimumZoomHandler(for: snapshot.path),
                    onAction: imageActionHandler(for: snapshot)
                )
            } else {
                imageView = ChatArtifactZoomableImageNativeView(
                    image: image,
                    onMinimumZoomChanged: imageMinimumZoomHandler(for: snapshot.path),
                    onAction: imageActionHandler(for: snapshot)
                )
                install(view: imageView, identity: .image)
                renderedImageData = data
            }
        case .pdf(let fileURL):
            if contentIdentity == .pdf(fileURL),
               let pdf = contentView as? ChatArtifactPDFNativeView {
                pdf.update(fileURL: fileURL)
            } else {
                install(
                    view: ChatArtifactPDFNativeView(fileURL: fileURL),
                    identity: .pdf(fileURL)
                )
            }
        case .media(let fileURL):
            if contentIdentity == .media(fileURL),
               let media = embeddedController as? AVPlayerViewController {
                ChatArtifactMediaController.update(media, fileURL: fileURL)
            } else {
                install(
                    controller: ChatArtifactMediaController.make(fileURL: fileURL),
                    identity: .media(fileURL)
                )
            }
        case .quickLook(let fileURL):
            if contentIdentity == .quickLook(fileURL),
               let quickLook = embeddedController as? QLPreviewController,
               let quickLookCoordinator {
                ChatArtifactQuickLookController.update(
                    quickLook,
                    coordinator: quickLookCoordinator,
                    fileURL: fileURL,
                    title: snapshot.displayName
                )
            } else {
                let coordinator = ChatArtifactQuickLookCoordinator(
                    item: ChatArtifactQuickLookItem(
                        fileURL: fileURL,
                        title: snapshot.displayName
                    )
                )
                quickLookCoordinator = coordinator
                install(
                    controller: ChatArtifactQuickLookController.make(dataSource: coordinator),
                    identity: .quickLook(fileURL)
                )
            }
        case .text:
            ensureTextView(identity: .text).update(
                snapshot: snapshot,
                actions: descriptor.actions(),
                traitCollection: traitCollection
            )
        case .markdown:
            if snapshot.markdownPresentation.mode == .rendered {
                let markdown: ChatArtifactMarkdownNativeView
                if contentIdentity == .markdownRendered,
                   let existing = contentView as? ChatArtifactMarkdownNativeView {
                    markdown = existing
                } else {
                    markdown = ChatArtifactMarkdownNativeView(markdown: snapshot.renderedText)
                    install(view: markdown, identity: .markdownRendered)
                }
                markdown.update(markdown: snapshot.renderedText)
            } else {
                ensureTextView(identity: .markdownRaw).update(
                    snapshot: snapshot,
                    actions: descriptor.actions(),
                    traitCollection: traitCollection
                )
            }
        case .binary(let stat):
            installUnavailableView(
                identity: .binary(stat.size),
                title: String(
                    localized: "chat.artifact.preview_unavailable.title",
                    defaultValue: "Preview unavailable",
                    bundle: .module
                ),
                message: String(
                    localized: "chat.artifact.preview_unavailable.message",
                    defaultValue: "This file can't be previewed.",
                    bundle: .module
                ),
                detail: formattedSize(stat.size)
            )
        case .tooLarge(let actualSize, let limit):
            installUnavailableView(
                identity: .tooLarge(actualSize, limit),
                title: String(
                    localized: "chat.artifact.too_large.title",
                    defaultValue: "File too large to preview",
                    bundle: .module
                ),
                message: tooLargeMessage(actualSize: actualSize, limit: limit)
            )
        case .unsupportedMedia:
            installUnavailableView(
                identity: .unsupportedMedia,
                title: String(
                    localized: "chat.artifact.preview_unavailable.title",
                    defaultValue: "Preview unavailable",
                    bundle: .module
                ),
                message: String(
                    localized: "chat.artifact.preview_unavailable.message",
                    defaultValue: "This file can't be previewed.",
                    bundle: .module
                )
            )
        case .fileMissing:
            installUnavailableView(
                identity: .fileMissing,
                title: String(
                    localized: "chat.artifact.file_missing.title",
                    defaultValue: "File not found",
                    bundle: .module
                ),
                message: String(
                    localized: "chat.artifact.file_missing.message",
                    defaultValue: "The file is no longer available on your Mac.",
                    bundle: .module
                )
            )
        case .macUnreachable:
            installUnavailableView(
                identity: .macUnreachable,
                title: String(
                    localized: "chat.artifact.mac_unreachable.title",
                    defaultValue: "Mac unreachable",
                    bundle: .module
                ),
                message: String(
                    localized: "chat.artifact.mac_unreachable.message",
                    defaultValue: "Check the connection to your Mac and try again.",
                    bundle: .module
                ),
                retry: descriptor.actions().retry
            )
        case .forbidden:
            installUnavailableView(
                identity: .forbidden,
                title: String(
                    localized: "chat.artifact.forbidden.title",
                    defaultValue: "Preview unavailable",
                    bundle: .module
                ),
                message: forbiddenMessage
            )
        }
    }

    private func ensureLoadingView() -> ChatArtifactLoadingNativeView {
        if contentIdentity == .loading,
           let loading = contentView as? ChatArtifactLoadingNativeView {
            return loading
        }
        let loading = ChatArtifactLoadingNativeView()
        install(view: loading, identity: .loading)
        return loading
    }

    @discardableResult
    private func ensureFolderController(path: String) -> ChatArtifactFolderNativeViewController {
        if contentIdentity == .folder(path),
           let folder = embeddedController as? ChatArtifactFolderNativeViewController {
            return folder
        }
        let folder = ChatArtifactFolderNativeViewController(
            path: path,
            scope: descriptor.scope,
            loader: descriptor.loader,
            onSelect: { [weak self] route in
                self?.openFolderRoute(route)
            }
        )
        install(controller: folder, identity: .folder(path))
        return folder
    }

    private func ensureTextView(identity: ContentIdentity) -> ChatArtifactTextPageNativeView {
        if contentIdentity == identity,
           let text = contentView as? ChatArtifactTextPageNativeView {
            return text
        }
        let text = ChatArtifactTextPageNativeView()
        install(view: text, identity: identity)
        return text
    }

    private func installUnavailableView(
        identity: ContentIdentity,
        title: String,
        message: String,
        detail: String? = nil,
        retry: (@MainActor () -> Void)? = nil
    ) {
        if contentIdentity == identity { return }
        install(
            view: ChatArtifactUnavailableNativeView(
                title: title,
                message: message,
                detail: detail,
                retry: retry
            ),
            identity: identity
        )
    }

    private func installEmptyView(identity: ContentIdentity) {
        guard contentIdentity != identity else { return }
        install(view: UIView(), identity: identity)
    }

    private func install(view installedView: UIView, identity: ContentIdentity) {
        removeInstalledContent()
        contentIdentity = identity
        contentView = installedView
        installedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(installedView)
        NSLayoutConstraint.activate([
            installedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            installedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            installedView.topAnchor.constraint(equalTo: view.topAnchor),
            installedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func install(controller: UIViewController, identity: ContentIdentity) {
        removeInstalledContent()
        contentIdentity = identity
        embeddedController = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func removeInstalledContent() {
        if let media = embeddedController as? AVPlayerViewController {
            ChatArtifactMediaController.dismantle(media)
        }
        if let embeddedController {
            embeddedController.willMove(toParent: nil)
            embeddedController.view.removeFromSuperview()
            embeddedController.removeFromParent()
        }
        contentView?.removeFromSuperview()
        embeddedController = nil
        contentView = nil
        quickLookCoordinator = nil
        renderedImageData = nil
    }

    private func openFolderRoute(_ route: ChatArtifactFolderRoute) {
        let model = ChatArtifactViewerPageModel(
            path: route.path,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        )
        let child = ChatArtifactViewerPageController(descriptor: ChatArtifactViewerPageDescriptor(
            model: model,
            scope: route.scope,
            loader: route.loader,
            onImageMinimumZoomChanged: descriptor.onImageMinimumZoomChanged,
            onImageAction: descriptor.onImageAction,
            onDone: descriptor.onDone
        ))
        child.title = URL(fileURLWithPath: route.path).lastPathComponent
        if let navigationController {
            navigationController.pushViewController(child, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: child)
            present(navigation, animated: true)
        }
    }

    private func image(for data: Data) -> UIImage? {
        if renderedImageData == data,
           let imageView = contentView as? ChatArtifactZoomableImageNativeView,
           let existing = imageView.subviews.compactMap({ $0 as? UIImageView }).first?.image {
            return existing
        }
        renderedImageData = data
        return UIImage(data: data)
    }

    private func imageMinimumZoomHandler(for path: String) -> (Bool) -> Void {
        { [weak self] isAtMinimum in
            self?.descriptor.onImageMinimumZoomChanged(path, isAtMinimum)
        }
    }

    private func imageActionHandler(
        for snapshot: ChatArtifactViewerPageSnapshot
    ) -> @MainActor (ChatArtifactAction) -> Void {
        { [weak self] action in
            self?.descriptor.onImageAction(action, snapshot)
        }
    }

    private func startLifecycleIfNeeded() {
        guard lifecycleTask == nil else { return }
        let actions = descriptor.actions()
        lifecycleTask = Task {
            await actions.load()
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            for await _ in stream {}
            await actions.cleanup()
        }
    }

    private func stopLifecycle() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
    }

    private func restartLifecycle() {
        let previous = lifecycleTask
        previous?.cancel()
        lifecycleTask = nil
        let actions = descriptor.actions()
        lifecycleTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await actions.load()
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            for await _ in stream {}
            await actions.cleanup()
        }
    }

    private var forbiddenMessage: String {
        switch descriptor.scope {
        case .chat:
            String(
                localized: "chat.artifact.forbidden.message",
                defaultValue: "This file was not referenced by the conversation.",
                bundle: .module
            )
        case .terminal:
            String(
                localized: "chat.artifact.forbidden.terminal_message",
                defaultValue: "This file isn't visible in the current terminal view.",
                bundle: .module
            )
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func tooLargeMessage(actualSize: Int64?, limit: Int64) -> String {
        guard let actualSize else {
            let format = String(
                localized: "chat.artifact.too_large.limit_message",
                defaultValue: "This preview is limited to %@.",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, formattedSize(limit))
        }
        let format = String(
            localized: "chat.artifact.too_large.message",
            defaultValue: "This file is %@; previews are limited to %@.",
            bundle: .module
        )
        return String.localizedStringWithFormat(
            format,
            formattedSize(actualSize),
            formattedSize(limit)
        )
    }

    private enum ContentIdentity: Equatable {
        case loading
        case folder(String)
        case image
        case pdf(URL)
        case media(URL)
        case quickLook(URL)
        case text
        case markdownRaw
        case markdownRendered
        case binary(Int64)
        case tooLarge(Int64?, Int64)
        case unsupportedMedia
        case fileMissing
        case macUnreachable
        case forbidden
        case empty
    }
}

@MainActor
private final class ChatArtifactLoadingNativeView: UIView {
    private let progress = UIProgressView(progressViewStyle: .default)
    private let activity = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = String(
            localized: "chat.artifact.loading",
            defaultValue: "Loading preview",
            bundle: .module
        )
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        detailLabel.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        detailLabel.textColor = .tertiaryLabel
        detailLabel.textAlignment = .center
        activity.startAnimating()
        let stack = UIStackView(arrangedSubviews: [progress, activity, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(fetched: Int64, total: Int64?) {
        if let total, total > 0 {
            progress.isHidden = false
            activity.isHidden = true
            progress.progress = Float(Double(fetched) / Double(total))
            detailLabel.text = "\(formattedSize(fetched)) / \(formattedSize(total))"
        } else {
            progress.isHidden = true
            activity.isHidden = false
            progress.progress = 0
            detailLabel.text = fetched > 0 ? formattedSize(fetched) : nil
        }
        detailLabel.isHidden = detailLabel.text == nil
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
private final class ChatArtifactUnavailableNativeView: UIView {
    init(
        title: String,
        message: String,
        detail: String?,
        retry: (@MainActor () -> Void)?
    ) {
        super.init(frame: .zero)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        if let detail {
            let detailLabel = UILabel()
            detailLabel.text = detail
            detailLabel.font = .monospacedDigitSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .regular
            )
            detailLabel.textColor = .tertiaryLabel
            stack.addArrangedSubview(detailLabel)
        }
        if let retry {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.borderedProminent()
            configuration.title = String(
                localized: "chat.artifact.retry",
                defaultValue: "Retry",
                bundle: .module
            )
            configuration.image = UIImage(systemName: "arrow.clockwise")
            configuration.imagePadding = 6
            button.configuration = configuration
            button.addAction(UIAction { _ in retry() }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(14, after: messageLabel)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ChatArtifactTextPageNativeView: UIView, UITextFieldDelegate {
    private let stack = UIStackView()
    private let streamingHeader = UIStackView()
    private let streamingProgress = UIProgressView(progressViewStyle: .default)
    private let streamingLabel = UILabel()
    private let searchStack = UIStackView()
    private let searchRow = UIStackView()
    private let searchField = UITextField()
    private let searchSummary = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let closeSearchButton = UIButton(type: .system)
    private let stillLoadingRow = UIStackView()
    private let goToLineRow = UIStackView()
    private let goToLineField = UITextField()
    private let goButton = UIButton(type: .system)
    private let closeGoToLineButton = UIButton(type: .system)
    private let highlightingRow = UIStackView()
    private let highlightingButton = UIButton(type: .system)
    private let textView = ChatArtifactTextNativeView(configuration: .empty)
    private var actions: ChatArtifactViewerPageActions?
    private var snapshot: ChatArtifactViewerPageSnapshot?
    private var highlightingExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        snapshot: ChatArtifactViewerPageSnapshot,
        actions: ChatArtifactViewerPageActions,
        traitCollection: UITraitCollection
    ) {
        let searchWasHidden = searchStack.isHidden
        let goToLineWasHidden = goToLineRow.isHidden
        self.snapshot = snapshot
        self.actions = actions

        streamingHeader.isHidden = snapshot.textReachedEOF
        if !snapshot.textReachedEOF {
            if let total = snapshot.totalBytes, total > 0 {
                streamingProgress.progress = Float(Double(snapshot.fetchedBytes) / Double(total))
            } else {
                streamingProgress.progress = 0
            }
            streamingLabel.text = progressText(
                fetched: snapshot.fetchedBytes,
                total: snapshot.totalBytes
            )
        }

        searchStack.isHidden = !snapshot.isSearchPresented
        if searchField.text != snapshot.searchQuery {
            searchField.text = snapshot.searchQuery
        }
        searchSummary.text = snapshot.searchQuery.isEmpty
            ? nil
            : "\(snapshot.searchSummary.currentPosition)/\(snapshot.searchSummary.matchCount)"
        searchSummary.isHidden = searchSummary.text == nil
        let hasMatches = !snapshot.searchQuery.isEmpty && snapshot.searchSummary.matchCount > 0
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
        stillLoadingRow.isHidden = snapshot.textReachedEOF || snapshot.searchQuery.isEmpty

        goToLineRow.isHidden = !snapshot.isGoToLinePresented
        if goToLineField.text != snapshot.goToLineText {
            goToLineField.text = snapshot.goToLineText
        }
        goButton.isEnabled = Int(snapshot.goToLineText) != nil

        highlightingRow.isHidden = !snapshot.showsHighlightingStatusPill
        updateHighlightingButton(snapshot: snapshot)

        textView.update(configuration: ChatArtifactTextViewConfiguration(
            documentID: snapshot.path,
            chunks: snapshot.textChunks,
            reachedEOF: snapshot.textReachedEOF,
            highlightDecision: snapshot.textHighlightDecision,
            highlightTheme: traitCollection.userInterfaceStyle == .dark ? .dark : .light,
            searchQuery: snapshot.searchQuery,
            previousSearchRequestID: snapshot.previousSearchRequestID,
            nextSearchRequestID: snapshot.nextSearchRequestID,
            onSearchSummaryChanged: actions.setSearchSummary,
            lineIndex: snapshot.textLineIndex,
            showsLineNumbers: snapshot.showsLineNumbers,
            goToLineUTF16Offset: snapshot.goToLineUTF16Offset,
            goToLineRequestID: snapshot.goToLineRequestID,
            wrapsLines: snapshot.wrapsLines,
            fontPointSize: snapshot.textFontSize,
            onFontSizeChanged: actions.setFontSize,
            topRequestID: snapshot.topRequestID,
            bottomRequestID: snapshot.bottomRequestID
        ))

        if searchWasHidden, !searchStack.isHidden {
            searchField.becomeFirstResponder()
        } else if goToLineWasHidden, !goToLineRow.isHidden {
            goToLineField.becomeFirstResponder()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        if textField === searchField {
            actions?.selectNextSearchResult()
        } else if textField === goToLineField,
                  let line = Int(textField.text ?? "") {
            actions?.goToLine(line)
        }
        return true
    }

    private func configureViews() {
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        streamingLabel.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        streamingLabel.textColor = .secondaryLabel
        streamingHeader.axis = .horizontal
        streamingHeader.alignment = .center
        streamingHeader.spacing = 10
        streamingHeader.isLayoutMarginsRelativeArrangement = true
        streamingHeader.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 6,
            leading: 16,
            bottom: 6,
            trailing: 16
        )
        streamingHeader.backgroundColor = .secondarySystemBackground
        streamingHeader.addArrangedSubview(streamingProgress)
        streamingHeader.addArrangedSubview(streamingLabel)
        streamingProgress.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        stack.addArrangedSubview(streamingHeader)

        searchField.placeholder = String(
            localized: "chat.artifact.search.placeholder",
            defaultValue: "Find in file",
            bundle: .module
        )
        searchField.borderStyle = .roundedRect
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchSummary.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        searchSummary.textColor = .secondaryLabel
        configureSymbolButton(
            previousButton,
            symbol: "chevron.up",
            accessibilityLabel: String(
                localized: "chat.artifact.search.previous",
                defaultValue: "Previous match",
                bundle: .module
            ),
            selector: #selector(selectPrevious)
        )
        configureSymbolButton(
            nextButton,
            symbol: "chevron.down",
            accessibilityLabel: String(
                localized: "chat.artifact.search.next",
                defaultValue: "Next match",
                bundle: .module
            ),
            selector: #selector(selectNext)
        )
        configureSymbolButton(
            closeSearchButton,
            symbol: "xmark.circle.fill",
            accessibilityLabel: String(
                localized: "chat.artifact.search.close",
                defaultValue: "Close search",
                bundle: .module
            ),
            selector: #selector(closeSearch)
        )
        searchRow.axis = .horizontal
        searchRow.alignment = .center
        searchRow.spacing = 8
        [searchField, searchSummary, previousButton, nextButton, closeSearchButton].forEach {
            searchRow.addArrangedSubview($0)
        }

        let stillLoadingSpinner = UIActivityIndicatorView(style: .medium)
        stillLoadingSpinner.startAnimating()
        let stillLoadingLabel = UILabel()
        stillLoadingLabel.text = String(
            localized: "chat.artifact.search.still_loading",
            defaultValue: "Still loading",
            bundle: .module
        )
        stillLoadingLabel.font = .preferredFont(forTextStyle: .caption2)
        stillLoadingLabel.textColor = .tertiaryLabel
        stillLoadingRow.axis = .horizontal
        stillLoadingRow.alignment = .center
        stillLoadingRow.spacing = 5
        stillLoadingRow.addArrangedSubview(stillLoadingSpinner)
        stillLoadingRow.addArrangedSubview(stillLoadingLabel)
        stillLoadingRow.addArrangedSubview(UIView())

        searchStack.axis = .vertical
        searchStack.alignment = .fill
        searchStack.spacing = 4
        searchStack.isLayoutMarginsRelativeArrangement = true
        searchStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: 12,
            bottom: 8,
            trailing: 12
        )
        searchStack.backgroundColor = .secondarySystemBackground
        searchStack.addArrangedSubview(searchRow)
        searchStack.addArrangedSubview(stillLoadingRow)
        stack.addArrangedSubview(searchStack)

        goToLineField.placeholder = String(
            localized: "chat.artifact.line.placeholder",
            defaultValue: "Line number",
            bundle: .module
        )
        goToLineField.borderStyle = .roundedRect
        goToLineField.keyboardType = .numberPad
        goToLineField.delegate = self
        goToLineField.addTarget(self, action: #selector(goToLineChanged), for: .editingChanged)
        var goConfiguration = UIButton.Configuration.borderedProminent()
        goConfiguration.title = String(
            localized: "chat.artifact.line.go",
            defaultValue: "Go",
            bundle: .module
        )
        goButton.configuration = goConfiguration
        goButton.addTarget(self, action: #selector(goToLine), for: .primaryActionTriggered)
        configureSymbolButton(
            closeGoToLineButton,
            symbol: "xmark.circle.fill",
            accessibilityLabel: String(
                localized: "chat.artifact.line.close",
                defaultValue: "Close go to line",
                bundle: .module
            ),
            selector: #selector(closeGoToLine)
        )
        goToLineRow.axis = .horizontal
        goToLineRow.alignment = .center
        goToLineRow.spacing = 8
        goToLineRow.isLayoutMarginsRelativeArrangement = true
        goToLineRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: 12,
            bottom: 8,
            trailing: 12
        )
        goToLineRow.backgroundColor = .secondarySystemBackground
        [goToLineField, goButton, closeGoToLineButton].forEach {
            goToLineRow.addArrangedSubview($0)
        }
        stack.addArrangedSubview(goToLineRow)

        var highlightingConfiguration = UIButton.Configuration.gray()
        highlightingConfiguration.image = UIImage(systemName: "paintbrush.slash")
        highlightingConfiguration.imagePadding = 8
        highlightingButton.configuration = highlightingConfiguration
        highlightingButton.addTarget(
            self,
            action: #selector(toggleHighlightingExplanation),
            for: .primaryActionTriggered
        )
        highlightingRow.axis = .horizontal
        highlightingRow.alignment = .center
        highlightingRow.isLayoutMarginsRelativeArrangement = true
        highlightingRow.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: 12,
            bottom: 8,
            trailing: 12
        )
        highlightingRow.addArrangedSubview(UIView())
        highlightingRow.addArrangedSubview(highlightingButton)
        stack.addArrangedSubview(highlightingRow)
        stack.addArrangedSubview(textView)
    }

    private func configureSymbolButton(
        _ button: UIButton,
        symbol: String,
        accessibilityLabel: String,
        selector: Selector
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: selector, for: .primaryActionTriggered)
    }

    private func updateHighlightingButton(snapshot: ChatArtifactViewerPageSnapshot) {
        guard let totalBytes = snapshot.totalBytes else { return }
        var configuration = highlightingButton.configuration
        if highlightingExpanded {
            let format = String(
                localized: "chat.artifact.highlighting.off.explanation",
                defaultValue: "This file is %@. Syntax highlighting is off above %@ to keep scrolling smooth.",
                bundle: .module
            )
            configuration?.title = String.localizedStringWithFormat(
                format,
                formattedSize(totalBytes),
                formattedSize(ChatArtifactSyntaxHighlightPolicy.maxHighlightBytes)
            )
        } else {
            configuration?.title = String(
                localized: "chat.artifact.highlighting.off",
                defaultValue: "Highlighting off",
                bundle: .module
            )
        }
        configuration?.image = UIImage(
            systemName: highlightingExpanded ? "xmark.circle.fill" : "paintbrush.slash"
        )
        highlightingButton.configuration = configuration
    }

    @objc private func searchChanged() {
        actions?.setSearchQuery(searchField.text ?? "")
    }

    @objc private func selectPrevious() {
        actions?.selectPreviousSearchResult()
    }

    @objc private func selectNext() {
        actions?.selectNextSearchResult()
    }

    @objc private func closeSearch() {
        searchField.resignFirstResponder()
        actions?.dismissSearch()
    }

    @objc private func goToLineChanged() {
        let text = goToLineField.text ?? ""
        actions?.setGoToLineText(text)
        goButton.isEnabled = Int(text) != nil
    }

    @objc private func goToLine() {
        guard let line = Int(goToLineField.text ?? "") else { return }
        goToLineField.resignFirstResponder()
        actions?.goToLine(line)
    }

    @objc private func closeGoToLine() {
        goToLineField.resignFirstResponder()
        actions?.dismissGoToLine()
    }

    @objc private func toggleHighlightingExplanation() {
        highlightingExpanded.toggle()
        if let snapshot { updateHighlightingButton(snapshot: snapshot) }
    }

    private func progressText(fetched: Int64, total: Int64?) -> String {
        if let total {
            return "\(formattedSize(fetched)) / \(formattedSize(total))"
        }
        return formattedSize(fetched)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension ChatArtifactTextViewConfiguration {
    static var empty: ChatArtifactTextViewConfiguration {
        ChatArtifactTextViewConfiguration(
            documentID: "",
            chunks: [],
            reachedEOF: true,
            highlightDecision: .skippedNoLanguage,
            highlightTheme: .light,
            searchQuery: "",
            previousSearchRequestID: 0,
            nextSearchRequestID: 0,
            onSearchSummaryChanged: { _ in },
            lineIndex: ChatArtifactLineIndex(),
            showsLineNumbers: true,
            goToLineUTF16Offset: 0,
            goToLineRequestID: 0,
            wrapsLines: true,
            fontPointSize: Double(UIFont.preferredFont(forTextStyle: .body).pointSize),
            onFontSizeChanged: { _ in },
            topRequestID: 0,
            bottomRequestID: 0
        )
    }
}
#endif
