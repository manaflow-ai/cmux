public import AppKit
public import ExtensionFoundation
public import ExtensionKit
@_spi(CmuxHostTransport) public import CmuxExtensionKit
public import Foundation

/// Native controller that embeds an ExtensionKit sidebar scene.
@available(macOS 14.0, *)
@MainActor
@_spi(CmuxHostTransport)
public final class CMUXSidebarExtensionHostView: NSViewController, EXHostViewControllerDelegate {
    private struct HostConfigurationKey: Equatable {
        var bundleIdentifier: String
        var sceneID: String
    }

    private let extensionController = EXHostViewController()
    private var currentKey: HostConfigurationKey?
    private var identity: AppExtensionIdentity
    private var sceneID: String
    private var onConnection: (@MainActor (NSXPCConnection) -> Void)?
    private var onDeactivation: (@MainActor ((any Error)?) -> Void)?
    private var onTeardown: (@MainActor () -> Void)?
    private var isTornDown = false

    public init(
        identity: AppExtensionIdentity,
        sceneID: String = CmuxSidebarExtensionPoint.defaultSceneID,
        onConnection: (@MainActor (NSXPCConnection) -> Void)? = nil,
        onDeactivation: (@MainActor ((any Error)?) -> Void)? = nil,
        onTeardown: (@MainActor () -> Void)? = nil
    ) {
        self.identity = identity
        self.sceneID = sceneID
        self.onConnection = onConnection
        self.onDeactivation = onDeactivation
        self.onTeardown = onTeardown
        super.init(nibName: nil, bundle: nil)
        applyConfigurationIfNeeded()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let container = NSView()
        view = container
        addChild(extensionController)
        let hostedView = extensionController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        extensionController.delegate = self
    }

    /// Reconfigures the existing controller without rebuilding its AppKit
    /// containment hierarchy.
    public func update(
        identity: AppExtensionIdentity,
        sceneID: String = CmuxSidebarExtensionPoint.defaultSceneID,
        onConnection: (@MainActor (NSXPCConnection) -> Void)? = nil,
        onDeactivation: (@MainActor ((any Error)?) -> Void)? = nil,
        onTeardown: (@MainActor () -> Void)? = nil
    ) {
        self.identity = identity
        self.sceneID = sceneID
        self.onConnection = onConnection
        self.onDeactivation = onDeactivation
        self.onTeardown = onTeardown
        isTornDown = false
        applyConfigurationIfNeeded()
    }

    public func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
        guard let onConnection else { return }
        do {
            onConnection(try viewController.makeXPCConnection())
        } catch {
            onDeactivation?(error)
        }
    }

    public func hostViewControllerWillDeactivate(
        _ viewController: EXHostViewController,
        error: (any Error)?
    ) {
        onDeactivation?(error)
    }

    /// Ends the extension scene and runs the owner's cleanup exactly once.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        onTeardown?()
        currentKey = nil
        extensionController.delegate = nil
        extensionController.configuration = nil
    }

    private func applyConfigurationIfNeeded() {
        let key = HostConfigurationKey(
            bundleIdentifier: identity.bundleIdentifier,
            sceneID: sceneID
        )
        guard currentKey != key else { return }
        currentKey = key
        extensionController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
    }
}
