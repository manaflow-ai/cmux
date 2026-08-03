public import AppKit
public import ExtensionFoundation
@_spi(CmuxHostTransport) public import CmuxExtensionKit
public import Foundation

/// Native controller that launches a UI-less sidebar extension process and
/// renders its typed presentation tree locally.
@available(macOS 14.0, *)
@MainActor
@_spi(CmuxHostTransport)
public final class CMUXSidebarExtensionHostView: NSViewController {
    private var identity: AppExtensionIdentity
    private var presentation: CmuxSidebarPresentation?
    private var onConnection: (@MainActor (NSXPCConnection) -> Void)?
    private var onDeactivation: (@MainActor ((any Error)?) -> Void)?
    private var onTeardown: (@MainActor () -> Void)?
    private var onPresentationAction: (@MainActor (String) -> Void)?
    private var process: AppExtensionProcess?
    private var activationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isTornDown = false
    private let presentationView = CMUXSidebarPresentationView()

    public init(
        identity: AppExtensionIdentity,
        presentation: CmuxSidebarPresentation? = nil,
        onConnection: (@MainActor (NSXPCConnection) -> Void)? = nil,
        onDeactivation: (@MainActor ((any Error)?) -> Void)? = nil,
        onTeardown: (@MainActor () -> Void)? = nil,
        onPresentationAction: (@MainActor (String) -> Void)? = nil
    ) {
        self.identity = identity
        self.presentation = presentation
        self.onConnection = onConnection
        self.onDeactivation = onDeactivation
        self.onTeardown = onTeardown
        self.onPresentationAction = onPresentationAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("CMUXExtensionSidebarHostView")
        view = container
        presentationView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(presentationView)
        NSLayoutConstraint.activate([
            presentationView.topAnchor.constraint(equalTo: container.topAnchor),
            presentationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            presentationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            presentationView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        updatePresentationView()
        activateExtension()
    }

    /// Updates the existing host without rebuilding its AppKit hierarchy.
    public func update(
        identity: AppExtensionIdentity,
        presentation: CmuxSidebarPresentation? = nil,
        onConnection: (@MainActor (NSXPCConnection) -> Void)? = nil,
        onDeactivation: (@MainActor ((any Error)?) -> Void)? = nil,
        onTeardown: (@MainActor () -> Void)? = nil,
        onPresentationAction: (@MainActor (String) -> Void)? = nil
    ) {
        let identityChanged = self.identity.bundleIdentifier != identity.bundleIdentifier
        self.identity = identity
        self.presentation = presentation
        self.onConnection = onConnection
        self.onDeactivation = onDeactivation
        self.onTeardown = onTeardown
        self.onPresentationAction = onPresentationAction
        isTornDown = false
        if isViewLoaded {
            updatePresentationView()
            if identityChanged {
                activateExtension()
            }
        }
    }

    /// Stops the process and runs owner cleanup exactly once.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        generation &+= 1
        activationTask?.cancel()
        activationTask = nil
        process?.invalidate()
        process = nil
        onTeardown?()
    }

    private func updatePresentationView() {
        presentationView.update(
            presentation: presentation,
            onAction: { [weak self] actionID in
                self?.onPresentationAction?(actionID)
            }
        )
    }

    private func activateExtension() {
        generation &+= 1
        let activationGeneration = generation
        activationTask?.cancel()
        process?.invalidate()
        process = nil
        presentationView.showLoading()

        let identity = self.identity
        let interruption = CMUXExtensionProcessInterruption { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == activationGeneration else { return }
                process = nil
                onDeactivation?(nil)
            }
        }
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let process = try AppExtensionProcess(
                    configuration: AppExtensionProcess.Configuration(
                        appExtensionIdentity: identity,
                        onInterruption: { interruption.call() }
                    )
                )
                guard !Task.isCancelled, generation == activationGeneration else {
                    process.invalidate()
                    return
                }
                self.process = process
                onConnection?(try process.makeXPCConnection())
            } catch {
                guard !Task.isCancelled, generation == activationGeneration else { return }
                presentationView.showError(error.localizedDescription)
                onDeactivation?(error)
            }
        }
    }
}

private final class CMUXExtensionProcessInterruption: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func call() {
        handler()
    }
}
