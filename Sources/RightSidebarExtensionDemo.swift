#if compiler(>=6.3) && canImport(ExtensionFoundation) && canImport(ExtensionKit)
import AppKit
import ExtensionFoundation
import ExtensionKit
import Observation
import SwiftUI

enum RightSidebarExtensionPoint {
    static let identifier = "com.cmuxterm.app.debug.extkit.right-sidebar-panel"
    static let productionIdentifier = "com.cmuxterm.app.right-sidebar-panel"
    static let legacyIdentifier = "com.cmuxterm.right-sidebar-panel"
    static let matchingDiscoveryIdentifiers = [
        identifier,
        productionIdentifier,
        legacyIdentifier,
    ]
    static let sceneID = "cmux-right-sidebar-demo"
}

@available(macOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var cmuxRightSidebarPanel: AppExtensionPoint {
        Name("right-sidebar-panel")
        UserInterface(true)
        Scope(restriction: .none)
    }
}

@MainActor
final class RightSidebarExtensionDemoStore: ObservableObject {
    @Published var identities: [AppExtensionIdentity] = []
    @Published var selectedIdentityID: AppExtensionIdentity.ID?
    @Published var statusMessage: String = String(
        localized: "rightSidebar.extensionDemo.ready",
        defaultValue: "Ready"
    )
    @Published var isLoading: Bool = false
    @Published var isBundledDemoExtensionPresent: Bool = RightSidebarExtensionDemoStore.bundledDemoExtensionExists()
    @Published var registryGeneration: Int = 0

    private var monitor: Any?
    private var reloadGeneration = 0

    var selectedIdentity: AppExtensionIdentity? {
        guard let selectedIdentityID else {
            return identities.first
        }

        return identities.first { $0.id == selectedIdentityID } ?? identities.first
    }

    func reload() {
        guard !isLoading else { return }

        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        isBundledDemoExtensionPresent = Self.bundledDemoExtensionExists()
        statusMessage = String(
            localized: "rightSidebar.extensionDemo.loading",
            defaultValue: "Looking for demo extensions..."
        )

        Task {
            await loadIdentities(generation: generation)
        }
    }

    private func loadIdentities(generation: Int) async {
        do {
            if #available(macOS 26.0, *) {
                let monitor = AppExtensionPoint.Monitor()
                try await monitor.addAppExtensionPoint(.cmuxRightSidebarPanel)
                self.monitor = monitor
                observeMonitor(monitor)
                guard generation == reloadGeneration else { return }
                let monitorState = monitor.state
                let matchingIdentities = (try? await loadMatchingIdentities()) ?? []
                guard generation == reloadGeneration else { return }
                if matchingIdentities.isEmpty {
                    applyMonitorState(monitorState)
                } else {
                    applyDiscoveredIdentities(
                        matchingIdentities,
                        disabledCount: monitorState.disabledCount,
                        unapprovedCount: monitorState.unapprovedCount
                    )
                }
            } else {
                self.monitor = nil
                let discoveredIdentities = try await loadMatchingIdentities()
                guard generation == reloadGeneration else { return }
                applyDiscoveredIdentities(discoveredIdentities)
            }
        } catch {
            guard generation == reloadGeneration else { return }
            monitor = nil
            identities = []
            selectedIdentityID = nil
            statusMessage = String(
                localized: "rightSidebar.extensionDemo.errorStatus",
                defaultValue: "Extension discovery failed."
            ) + " \(error.localizedDescription)"
        }

        isLoading = false
    }

    @available(macOS 26.0, *)
    private func applyMonitorState(_ state: AppExtensionPoint.Monitor.State) {
        applyDiscoveredIdentities(
            state.identities,
            disabledCount: state.disabledCount,
            unapprovedCount: state.unapprovedCount
        )
    }

    private func applyDiscoveredIdentities(
        _ discoveredIdentities: [AppExtensionIdentity],
        disabledCount: Int = 0,
        unapprovedCount: Int = 0
    ) {
        isBundledDemoExtensionPresent = Self.bundledDemoExtensionExists()
        let previousIdentityIDs = identities.map(\.id)
        let sortedIdentities = uniqueIdentities(discoveredIdentities).sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
        let currentIdentityIDs = sortedIdentities.map(\.id)
        if currentIdentityIDs != previousIdentityIDs {
            registryGeneration += 1
        }

        let unavailableCount = disabledCount + unapprovedCount
        if sortedIdentities.isEmpty, !identities.isEmpty {
            let bundledIdentifier = RightSidebarExtensionDemoStore.bundledDemoExtensionBundleIdentifier()
            let bundledIdentities = identities.filter { identity in
                bundledIdentifier.map { $0 == identity.bundleIdentifier } == true &&
                    RightSidebarExtensionDemoStore.bundledDemoExtensionExists()
            }
            if !bundledIdentities.isEmpty {
                identities = bundledIdentities
                if selectedIdentityID.map({ id in !bundledIdentities.contains { $0.id == id } }) ?? true {
                    selectedIdentityID = bundledIdentities.first?.id
                }
                registryGeneration += 1
                statusMessage = String(
                    localized: "rightSidebar.extensionDemo.settlingStatus",
                    defaultValue: "Extension discovery is settling. Keeping the last extension."
                )
                return
            }
        }

        identities = sortedIdentities
        if selectedIdentityID.map({ id in !sortedIdentities.contains { $0.id == id } }) ?? true {
            selectedIdentityID = sortedIdentities.first?.id
        }

        if sortedIdentities.isEmpty {
            if unavailableCount > 0 {
                statusMessage = String(
                    localized: "rightSidebar.extensionDemo.unavailableStatus",
                    defaultValue: "Extension is registered but not available yet."
                )
            } else if isBundledDemoExtensionPresent {
                statusMessage = String(
                    localized: "rightSidebar.extensionDemo.registrationSettlingStatus",
                    defaultValue: "Bundled demo extension is installed. Waiting for macOS registration."
                )
            } else {
                statusMessage = String(
                    localized: "rightSidebar.extensionDemo.emptyStatus",
                    defaultValue: "No demo extension found."
                )
            }
        } else {
            statusMessage = String(
                localized: "rightSidebar.extensionDemo.foundStatus",
                defaultValue: "Demo extension discovered."
            )
        }
    }

    private func uniqueIdentities(_ discoveredIdentities: [AppExtensionIdentity]) -> [AppExtensionIdentity] {
        var seen = Set<AppExtensionIdentity.ID>()
        return discoveredIdentities.filter { identity in
            seen.insert(identity.id).inserted
        }
    }

    private static func bundledDemoExtensionExists() -> Bool {
        FileManager.default.fileExists(atPath: bundledDemoExtensionURL.path)
    }

    private static func bundledDemoExtensionBundleIdentifier() -> String? {
        Bundle(url: bundledDemoExtensionURL)?.bundleIdentifier
    }

    private static var bundledDemoExtensionURL: URL {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent("RightSidebarDemoExtension.appex", isDirectory: true)
        return extensionURL
    }

    @available(macOS 26.0, *)
    private func observeMonitor(_ monitor: AppExtensionPoint.Monitor) {
        _ = withObservationTracking {
            monitor.state
        } onChange: { [weak self, weak monitor] in
            Task { @MainActor in
                guard let self, let monitor else { return }
                guard (self.monitor as AnyObject?) === monitor else { return }
                self.applyMonitorState(monitor.state)
                self.observeMonitor(monitor)
            }
        }
    }

    @available(macOS, introduced: 13.0, deprecated: 26.0, message: "Use AppExtensionPoint.Monitor")
    private func loadMatchingIdentities() async throws -> [AppExtensionIdentity] {
        var discoveredIdentities: [AppExtensionIdentity] = []
        for identifier in RightSidebarExtensionPoint.matchingDiscoveryIdentifiers {
            let identities = try AppExtensionIdentity.matching(appExtensionPointIDs: identifier)
            var iterator = identities.makeAsyncIterator()
            discoveredIdentities.append(contentsOf: await iterator.next() ?? [])
        }
        return uniqueIdentities(discoveredIdentities)
    }
}

struct RightSidebarExtensionDemoPanelView: View {
    @StateObject private var store = RightSidebarExtensionDemoStore()
    @State private var isPromptInfoPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text(String(localized: "rightSidebar.extensionDemo.title", defaultValue: "ExtensionKit Demo"))
            } icon: {
                Image(systemName: "puzzlepiece.extension")
            }
            .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 0)

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "rightSidebar.extensionDemo.refresh", defaultValue: "Refresh extensions"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        if #available(macOS 26.0, *) {
            extensionContent
        } else {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "rightSidebar.extensionDemo.requiresMacOS26",
                    defaultValue: "ExtensionKit sidebar demos require macOS 26."
                ))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }

    private var extensionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if store.identities.isEmpty {
                Spacer(minLength: 0)
                if store.isBundledDemoExtensionPresent {
                    VStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(
                            localized: "rightSidebar.extensionDemo.waitingForBundledDemo",
                            defaultValue: "Bundled demo extension is installed. Waiting for macOS to finish registration."
                        ))
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "exclamationmark.magnifyingglass")
                            .font(.system(size: 21))
                            .foregroundStyle(.secondary)
                        Text(String(
                            localized: "rightSidebar.extensionDemo.noExtensions",
                            defaultValue: "No ExtensionKit demo extension is registered yet."
                        ))
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        Text(String(
                            localized: "rightSidebar.extensionDemo.copyPromptHint",
                            defaultValue: "Copy a starter prompt and paste it into your AI agent to generate a sidebar extension."
                        ))
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button {
                                copyStarterPrompt()
                            } label: {
                                Label(
                                    String(localized: "rightSidebar.extensionDemo.copyPrompt", defaultValue: "Copy extension prompt"),
                                    systemImage: "doc.on.clipboard"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                isPromptInfoPresented.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                            .help(String(
                                localized: "rightSidebar.extensionDemo.promptInfo",
                                defaultValue: "About this prompt"
                            ))
                            .popover(isPresented: $isPromptInfoPresented, arrowEdge: .trailing) {
                                ExtensionPromptInfoPopover(
                                    prompt: Self.starterPrompt,
                                    copyAction: copyStarterPrompt
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            } else {
                Picker(
                    String(localized: "rightSidebar.extensionDemo.extensionPicker", defaultValue: "Extension"),
                    selection: $store.selectedIdentityID
                ) {
                    ForEach(store.identities, id: \.id) { identity in
                        Text(identity.localizedName)
                            .tag(Optional(identity.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let identity = store.selectedIdentity {
                    ExtensionKitSidebarHostView(
                        identity: identity,
                        registryGeneration: store.registryGeneration,
                        statusMessage: $store.statusMessage
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    extensionIdentityFooter(identity)
                }
            }
        }
        .padding(10)
    }

    private func extensionIdentityFooter(_ identity: AppExtensionIdentity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(identity.bundleIdentifier)
                .lineLimit(1)
            Text(identity.extensionPointIdentifier)
                .lineLimit(1)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .help("\(identity.bundleIdentifier)\n\(identity.extensionPointIdentifier)")
    }

    private func copyStarterPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.starterPrompt, forType: .string)
        store.statusMessage = String(
            localized: "rightSidebar.extensionDemo.copyPromptCopied",
            defaultValue: "Starter prompt copied."
        )
    }

    private static var starterPrompt: String {
        String(
            localized: "rightSidebar.extensionDemo.copyPromptBody",
            defaultValue: """
            Build a cmux right sidebar ExtensionKit demo extension in Swift.

            Requirements:
            - Use ExtensionFoundation and ExtensionKit.
            - Bind to app extension point com.cmuxterm.app.debug.extkit.right-sidebar-panel.
            - Provide a PrimitiveAppExtensionScene with scene id cmux-right-sidebar-demo.
            - Render a compact SwiftUI panel that fits a narrow right sidebar.
            - Return AppExtensionSceneConfiguration(body) from the AppExtension configuration and do not install a custom NSXPCConnection acceptor for the scene.
            - Add the Info.plist and Xcode project settings needed for an ExtensionKit .appex, including EXAppExtensionAttributes.EXExtensionPointIdentifier = com.cmuxterm.app.debug.extkit.right-sidebar-panel.
            - Keep all UI strings localized.
            """
        )
    }
}

private struct ExtensionPromptInfoPopover: View {
    let prompt: String
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(String(localized: "rightSidebar.extensionDemo.promptInfoTitle", defaultValue: "Extension prompt"))
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.system(size: 12, weight: .semibold))

            Text(String(
                localized: "rightSidebar.extensionDemo.promptInfoBody",
                defaultValue: "This prompt is copied only when you press Copy. It asks your AI agent to generate a Swift ExtensionKit sidebar extension that binds to cmux's right sidebar extension point."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(String(localized: "rightSidebar.extensionDemo.promptAuditTitle", defaultValue: "Full prompt"))
                .font(.system(size: 11, weight: .semibold))

            ScrollView {
                Text(prompt)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(width: 340, height: 170)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Button {
                copyAction()
            } label: {
                Label(
                    String(localized: "rightSidebar.extensionDemo.copyPrompt", defaultValue: "Copy extension prompt"),
                    systemImage: "doc.on.clipboard"
                )
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 368)
    }
}

struct ExtensionKitSidebarHostView: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    let registryGeneration: Int
    @Binding var statusMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(statusMessage: $statusMessage)
    }

    func makeNSViewController(context: Context) -> RightSidebarExtensionHostContainerController {
        let controller = RightSidebarExtensionHostContainerController()
        controller.configure(
            delegate: context.coordinator,
            placeholderView: NSHostingView(rootView: ExtensionKitHostPlaceholderView()),
            configuration: configuration,
            registryGeneration: registryGeneration
        )
        return controller
    }

    func updateNSViewController(_ controller: RightSidebarExtensionHostContainerController, context: Context) {
        context.coordinator.statusMessage = $statusMessage
        controller.hostViewController.delegate = context.coordinator

        if controller.hostViewController.configuration?.appExtension != identity ||
            controller.hostViewController.configuration?.sceneID != RightSidebarExtensionPoint.sceneID ||
            controller.registryGeneration != registryGeneration {
            controller.apply(configuration: configuration, registryGeneration: registryGeneration)
        }
    }

    private var configuration: EXHostViewController.Configuration {
        EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: RightSidebarExtensionPoint.sceneID
        )
    }

    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        var statusMessage: Binding<String>

        init(statusMessage: Binding<String>) {
            self.statusMessage = statusMessage
        }

        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            reconnectAttempts = 0
            statusMessage.wrappedValue = String(
                localized: "rightSidebar.extensionDemo.xpcConnected",
                defaultValue: "Extension scene activated."
            )
        }

        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: Error?) {
            if let error {
                statusMessage.wrappedValue = String(
                    localized: "rightSidebar.extensionDemo.deactivatedWithError",
                    defaultValue: "Extension scene disconnected:"
                ) + " \(error.localizedDescription)"
                retryAfterDisconnect(viewController)
            } else {
                statusMessage.wrappedValue = String(
                    localized: "rightSidebar.extensionDemo.deactivated",
                    defaultValue: "Extension scene disconnected."
                )
            }
        }

        private var reconnectAttempts = 0

        private func retryAfterDisconnect(_ viewController: EXHostViewController) {
            guard reconnectAttempts < 2,
                  let configuration = viewController.configuration else {
                return
            }
            reconnectAttempts += 1
            viewController.configuration = nil
            Task { @MainActor [weak viewController] in
                viewController?.configuration = configuration
            }
        }
    }
}

final class RightSidebarExtensionHostContainerController: NSViewController {
    let hostViewController = EXHostViewController()
    private(set) var registryGeneration: Int = -1

    override func loadView() {
        let containerView = RightSidebarExtensionInteractionView()
        containerView.identifier = cmuxRightSidebarExtensionHostContainerIdentifier
        view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostViewController)

        let hostedView = hostViewController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedView)
        if let interactionView = view as? RightSidebarExtensionInteractionView {
            interactionView.hostedContentView = hostedView
        }

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func configure(
        delegate: EXHostViewControllerDelegate,
        placeholderView: NSView,
        configuration: EXHostViewController.Configuration,
        registryGeneration: Int
    ) {
        hostViewController.delegate = delegate
        hostViewController.placeholderView = placeholderView
        apply(configuration: configuration, registryGeneration: registryGeneration)
    }

    func apply(
        configuration: EXHostViewController.Configuration,
        registryGeneration: Int
    ) {
        self.registryGeneration = registryGeneration
        hostViewController.configuration = configuration
    }
}

private final class RightSidebarExtensionInteractionView: NSView {
    weak var hostedContentView: NSView?
    private weak var lastPointerTarget: NSView?
    private var keyForwardingDepth = 0

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        if let target, Self.shouldClaimFocus(for: NSApp.currentEvent) {
            claimKeyboardFocus(startingAt: target)
        }
        return target
    }

    override func mouseDown(with event: NSEvent) {
        claimKeyboardFocus(startingAt: self)
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        claimKeyboardFocus(startingAt: self)
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        claimKeyboardFocus(startingAt: self)
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard forwardKeyDown(event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard forwardFlagsChanged(event) else {
            super.flagsChanged(with: event)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyForwardingDepth == 0,
           let target = preferredKeyTarget(),
           target !== self {
            keyForwardingDepth += 1
            defer { keyForwardingDepth = max(0, keyForwardingDepth - 1) }
            if target.performKeyEquivalent(with: event) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func forwardKeyDown(_ event: NSEvent) -> Bool {
        guard keyForwardingDepth == 0,
              let target = preferredKeyTarget(),
              target !== self else {
            return false
        }
        keyForwardingDepth += 1
        defer { keyForwardingDepth = max(0, keyForwardingDepth - 1) }
        target.keyDown(with: event)
        return true
    }

    private func forwardFlagsChanged(_ event: NSEvent) -> Bool {
        guard keyForwardingDepth == 0,
              let target = preferredKeyTarget(),
              target !== self else {
            return false
        }
        keyForwardingDepth += 1
        defer { keyForwardingDepth = max(0, keyForwardingDepth - 1) }
        target.flagsChanged(with: event)
        return true
    }

    private func preferredKeyTarget() -> NSView? {
        guard window?.firstResponder === self else { return nil }
        if let lastPointerTarget,
           lastPointerTarget !== self,
           lastPointerTarget.window === window,
           lastPointerTarget.isDescendant(of: self) {
            return lastPointerTarget
        }
        return hostedContentView
    }

    private static func shouldClaimFocus(for event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private func claimKeyboardFocus(startingAt target: NSView) {
        guard target === self || target.isDescendant(of: self) else { return }
        lastPointerTarget = target

        guard let window else { return }
        if let focusTarget = firstFocusableTarget(startingAt: target),
           window.makeFirstResponder(focusTarget) {
            return
        }
        _ = window.makeFirstResponder(self)
    }

    private func firstFocusableTarget(startingAt target: NSView) -> NSView? {
        var current: NSView? = target
        while let candidate = current {
            if candidate.acceptsFirstResponder {
                return candidate
            }
            if candidate === self {
                break
            }
            current = candidate.superview
        }
        return nil
    }
}

private struct ExtensionKitHostPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(
                localized: "rightSidebar.extensionDemo.placeholder",
                defaultValue: "Waiting for the extension scene..."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
    }
}
#else
import AppKit
import SwiftUI

enum RightSidebarExtensionPoint {
    static let identifier = "com.cmuxterm.app.debug.extkit.right-sidebar-panel"
    static let legacyIdentifier = "com.cmuxterm.right-sidebar-panel"
    static let sceneID = "cmux-right-sidebar-demo"
}

struct RightSidebarExtensionDemoPanelView: View {
    @State private var statusMessage = String(
        localized: "rightSidebar.extensionDemo.requiresMacOS26",
        defaultValue: "ExtensionKit sidebar demos require macOS 26."
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 9) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(statusMessage)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "rightSidebar.extensionDemo.copyPromptHint",
                    defaultValue: "Copy a starter prompt and paste it into your AI agent to generate a sidebar extension."
                ))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    copyStarterPrompt()
                } label: {
                    Label(
                        String(localized: "rightSidebar.extensionDemo.copyPrompt", defaultValue: "Copy extension prompt"),
                        systemImage: "doc.on.clipboard"
                    )
                }
                .controlSize(.small)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text(String(localized: "rightSidebar.extensionDemo.title", defaultValue: "ExtensionKit Demo"))
            } icon: {
                Image(systemName: "puzzlepiece.extension")
            }
            .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func copyStarterPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.starterPrompt, forType: .string)
        statusMessage = String(
            localized: "rightSidebar.extensionDemo.copyPromptCopied",
            defaultValue: "Starter prompt copied."
        )
    }

    private static var starterPrompt: String {
        String(
            localized: "rightSidebar.extensionDemo.copyPromptBody",
            defaultValue: """
            Build a cmux right sidebar ExtensionKit demo extension in Swift.

            Requirements:
            - Use ExtensionFoundation and ExtensionKit.
            - Bind to app extension point com.cmuxterm.app.debug.extkit.right-sidebar-panel.
            - Provide a PrimitiveAppExtensionScene with scene id cmux-right-sidebar-demo.
            - Render a compact SwiftUI panel that fits a narrow right sidebar.
            - Return AppExtensionSceneConfiguration(body) from the AppExtension configuration and do not install a custom NSXPCConnection acceptor for the scene.
            - Add the Info.plist and Xcode project settings needed for an ExtensionKit .appex, including EXAppExtensionAttributes.EXExtensionPointIdentifier = com.cmuxterm.app.debug.extkit.right-sidebar-panel.
            - Keep all UI strings localized.
            """
        )
    }
}
#endif
