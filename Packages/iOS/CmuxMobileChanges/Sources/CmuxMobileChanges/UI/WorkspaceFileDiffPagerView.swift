internal import Foundation

#if canImport(UIKit)
public import UIKit

/// Native swipe-paged diff viewer over an immutable changed-file snapshot.
@MainActor
public final class WorkspaceFileDiffPagerViewController: UIViewController,
    UIPageViewControllerDataSource,
    UIPageViewControllerDelegate
{
    private var files: [ChangedFileItem]
    private var cachedPresentations: [String: FileDiffPresentation]
    private var actions: WorkspaceFileDiffPagerActions
    private var selection: Int
    private var fontSize: Double
    private var scrollRowIDsByPath: [String: String] = [:]
    private var pagesByIndex: [Int: FileDiffPageViewController] = [:]
    private let mountPolicy = DiffPagerMountPolicy()

    private let titleLabel = UILabel()
    private let positionLabel = UILabel()
    private let pageController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal
    )
    private let emptyPageController = UIViewController()

    public init(
        files: [ChangedFileItem],
        initialSelectedIndex: Int,
        cachedPresentations: [String: FileDiffPresentation],
        initialFontSize: Double,
        actions: WorkspaceFileDiffPagerActions
    ) {
        self.files = files
        self.cachedPresentations = cachedPresentations
        self.actions = actions
        selection = files.isEmpty ? 0 : min(max(initialSelectedIndex, 0), files.count - 1)
        fontSize = min(
            max(initialFontSize, DiffFontPreference.minimumPointSize),
            DiffFontPreference.maximumPointSize
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
        view.accessibilityIdentifier = "MobileChangesDiffPager"

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        positionLabel.textAlignment = .center
        positionLabel.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.12)
        positionLabel.layer.cornerRadius = 12
        positionLabel.layer.masksToBounds = true
        positionLabel.setContentHuggingPriority(.required, for: .horizontal)
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        positionLabel.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let topBar = UIStackView(arrangedSubviews: [titleLabel, positionLabel])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 12
        topBar.isLayoutMarginsRelativeArrangement = true
        topBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        addChild(pageController)
        pageController.dataSource = self
        pageController.delegate = self
        emptyPageController.view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [topBar, separator, pageController.view])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pageController.didMove(toParent: self)
        synchronizePage(animated: false)
    }

    /// Reconciles refreshed file and cache snapshots while retaining the current page when possible.
    public func update(
        files: [ChangedFileItem],
        cachedPresentations: [String: FileDiffPresentation],
        actions: WorkspaceFileDiffPagerActions
    ) {
        let contentChanged = self.files != files || self.cachedPresentations != cachedPresentations
        let selectedPath = currentFile?.path
        self.files = files
        self.cachedPresentations = cachedPresentations
        self.actions = actions
        guard contentChanged else { return }
        if let selectedPath, let index = files.firstIndex(where: { $0.path == selectedPath }) {
            selection = index
        } else {
            selection = files.isEmpty ? 0 : min(selection, files.count - 1)
        }
        pagesByIndex.removeAll()
        guard isViewLoaded else { return }
        pageController.dataSource = nil
        pageController.dataSource = self
        synchronizePage(animated: false)
    }

    public func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? FileDiffPageViewController else { return nil }
        return controller(at: page.fileIndex - 1)
    }

    public func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? FileDiffPageViewController else { return nil }
        return controller(at: page.fileIndex + 1)
    }

    public func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed,
              let page = pageViewController.viewControllers?.first as? FileDiffPageViewController else { return }
        selection = page.fileIndex
        updateTopBar()
        recordSelectedPresentationAccess()
        prunePages()
    }

    private func controller(at index: Int) -> FileDiffPageViewController? {
        guard files.indices.contains(index) else { return nil }
        if let existing = pagesByIndex[index] { return existing }
        let file = files[index]
        let controller = FileDiffPageViewController(
            fileIndex: index,
            file: file,
            initialPresentation: cachedPresentations[file.path],
            initialScrollRowID: scrollRowIDsByPath[file.path],
            fontSize: fontSize,
            onFontSizeChanged: { [weak self] pointSize in
                guard let self else { return }
                self.fontSize = pointSize
                for page in self.pagesByIndex.values where page.fontSize != pointSize {
                    page.fontSize = pointSize
                    page.render()
                }
            },
            onScrollRowIDChanged: { [weak self] rowID in
                guard let self, let rowID else { return }
                self.scrollRowIDsByPath[file.path] = rowID
            },
            onPersistFontSize: actions.onPersistFontSize,
            onLoad: actions.onLoad,
            onLoadCurrentLines: actions.onLoadCurrentLines,
            onCopy: actions.onCopy,
            inlinePreview: actions.inlinePreview
        )
        pagesByIndex[index] = controller
        return controller
    }

    private func synchronizePage(animated: Bool) {
        updateTopBar()
        guard let controller = controller(at: selection) else {
            pageController.setViewControllers([emptyPageController], direction: .forward, animated: false)
            return
        }
        pageController.setViewControllers([controller], direction: .forward, animated: animated)
        recordSelectedPresentationAccess()
        prunePages()
    }

    private func updateTopBar() {
        titleLabel.text = currentFile?.displayFilename ?? ""
        positionLabel.text = "  \(DiffPagerPosition(selectedIndex: selection, pageCount: files.count).localizedText)  "
    }

    private var currentFile: ChangedFileItem? {
        guard files.indices.contains(selection) else { return nil }
        return files[selection]
    }

    private func recordSelectedPresentationAccess() {
        guard let currentFile else { return }
        actions.onPresentationAccess(currentFile.path)
    }

    private func prunePages() {
        let retained = Set(mountPolicy.mountedIndices(selectedIndex: selection, pageCount: files.count))
        pagesByIndex = pagesByIndex.filter { retained.contains($0.key) }
    }
}
#endif
