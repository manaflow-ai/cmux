public import AppKit
public import CmuxNextCloud
public import CmuxNextDesign
import Observation

/// The same connector card for Cloud setup and Auto's repository recovery.
/// Its client and repo-only retry are injected; it never creates a machine or writes credentials.
@MainActor
public final class CloudGitHubConnectorCard: NSView, NSSearchFieldDelegate {
    public enum Variant: String, CaseIterable { case compact, balanced, stacked }
    public let model: CloudGitHubConnectorModel
    public var onSelectRepository: (CloudMachineRepo) -> Void = { _ in }
    private let status = ThemedLabel(labelWithString: "")
    private let detail = ThemedLabel(wrappingLabelWithString: "")
    private let connect = ThemedBezelButton()
    private let refresh = ThemedBezelButton()
    private let more = ThemedBezelButton()
    private let search = NSSearchField()
    private let picker = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private var work: Task<Void, Never>?
    private var queryWork: Task<Void, Never>?
    private var activation: (any NSObjectProtocol)?
    private var busy = false
    private var observing = false
    private var shownRepositories: [CloudGitHubRepository] = []

    /// A balanced card is the default; compact and stacked are retained in the native gallery.
    public init(model: CloudGitHubConnectorModel, variant: Variant = .balanced) {
        self.model = model
        super.init(frame: .zero)
        let title = ThemedLabel(labelWithString: CloudGitHubConnectorStrings.title)
        title.font = Typography.bodyEmphasized
        status.font = Typography.caption
        detail.font = Typography.caption
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 300
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        connect.title = CloudGitHubConnectorStrings.connect
        refresh.title = CloudGitHubConnectorStrings.refresh
        more.title = CloudGitHubConnectorStrings.more
        for (button, selector) in [(connect, #selector(connectPressed)), (refresh, #selector(refreshPressed)), (more, #selector(morePressed))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = selector
        }
        search.placeholderString = CloudGitHubConnectorStrings.search
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(CloudGitHubConnectorStrings.search)
        picker.target = self
        picker.action = #selector(repoSelected)
        picker.setAccessibilityLabel(CloudGitHubConnectorStrings.repositories)
        let header = NSStackView(views: [title, spinner, NSView(), status])
        header.orientation = .horizontal
        let actions = NSStackView(views: [connect, refresh, NSView(), more])
        actions.orientation = .horizontal
        actions.spacing = Metrics.space2
        let contents: [NSView]
        switch variant {
        case .compact: contents = [header, actions, detail, search, picker]
        case .balanced: contents = [header, detail, actions, search, picker]
        case .stacked: contents = [title, status, spinner, detail, search, picker, actions]
        }
        let stack = NSStackView(views: contents)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = variant == .compact ? Metrics.space1 : Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor), picker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.cloud.githubConnector.\(variant.rawValue)")
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// In-context recovery shared with Auto; it never offers to create a second machine.
    public static func recoveryDialog(reason: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: CloudGitHubConnectorStrings.recoveryTitle, lines: [reason], buttons: [
            .cancel(CloudGitHubConnectorStrings.dismiss),
            CmuxDialogButton(id: "retry", title: CloudGitHubConnectorStrings.retry, role: .default),
        ], identifier: "cmux.dialog.cloud.githubRecovery")
    }

    /// Shared error copy for the Cloud and Auto repository recovery surfaces.
    public static func failureMessage(_ error: CloudGitHubConnectorClientError) -> String {
        CloudGitHubConnectorStrings.error(error)
    }

    /// Adds the card's controls to the standard dialog's focus trap.
    public var accessory: CmuxDialogAccessory {
        CmuxDialogAccessory(view: self, controls: [connect, refresh, more, search, picker])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let activation { NotificationCenter.default.removeObserver(activation); self.activation = nil }
        work?.cancel()
        queryWork?.cancel()
        guard window != nil else { busy = false; spinner.stopAnimation(nil); return }
        observe()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // task-owner: one notification delivery; the card checks its lifetime before starting owned work.
            Task { @MainActor [weak self] in
                guard let self, self.window != nil, !self.busy else { return }
                self.run { await self.model.resumeAfterInstall(); await self.loadRepositories() }
            }
        }
        run { await self.model.refresh(); await self.loadRepositories() }
    }

    private func observe() {
        guard !observing, window != nil else { return }
        observing = true
        withObservationTracking { render() } onChange: { [weak self] in
            // task-owner: one observation delivery; no observer is rearmed after the card leaves its window.
            Task { @MainActor [weak self] in
                self?.observing = false
                self?.observe()
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        render()
        // task-owner: this card; cancelled on removal from the dialog/window and deinit.
        work = Task { [weak self] in
            await operation()
            self?.busy = false
            self?.render()
        }
    }

    private func loadRepositories() async {
        guard !Task.isCancelled, model.state == .installed else { return }
        await model.searchRepositories(search.stringValue)
    }

    @objc private func connectPressed() { run { await self.model.connect() } }
    @objc private func refreshPressed() {
        run { await self.model.resumeAfterInstall(); await self.model.refresh(); await self.loadRepositories() }
    }
    @objc private func morePressed() { run { await self.model.loadMoreRepositories(query: self.search.stringValue) } }
    @objc private func repoSelected() {
        guard let id = picker.selectedItem?.representedObject as? String,
              let repo = try? CloudMachineRepo.parse(id) else { return }
        onSelectRepository(repo)
    }

    public func controlTextDidChange(_ notification: Notification) {
        queryWork?.cancel()
        let query = search.stringValue, model = model
        // task-owner: this card's latest search; cancelled by another search or removal.
        queryWork = Task { await model.searchRepositories(query) }
    }

    private func render() {
        status.stringValue = CloudGitHubConnectorStrings.state(model.state)
        detail.stringValue = model.error.map(CloudGitHubConnectorStrings.error) ?? CloudGitHubConnectorStrings.detail
        let working = busy || model.isRefreshing || model.isLoadingRepositories
        if working && window != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connect.title = model.state == .installed ? CloudGitHubConnectorStrings.manage : CloudGitHubConnectorStrings.connect
        connect.isEnabled = !working
        refresh.isEnabled = !working
        more.isEnabled = !working && model.repositoryCursor != nil
        search.isEnabled = model.state == .installed
        picker.isEnabled = model.state == .installed && !model.repositories.isEmpty
        if shownRepositories != model.repositories || picker.numberOfItems == 0 {
            let selected = picker.selectedItem?.representedObject as? String
            picker.removeAllItems()
            picker.addItem(withTitle: CloudGitHubConnectorStrings.repositories)
            for repo in model.repositories {
                picker.addItem(withTitle: repo.id + (repo.isPrivate ? " · " + CloudGitHubConnectorStrings.privateLabel : ""))
                picker.lastItem?.representedObject = repo.id
            }
            if let selected, let item = picker.itemArray.first(where: { $0.representedObject as? String == selected }) { picker.select(item) }
            shownRepositories = model.repositories
        }
    }

    nonisolated deinit { work?.cancel(); queryWork?.cancel() }
}
