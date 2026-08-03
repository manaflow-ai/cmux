import Bonsplit
import CmuxAppKitSupportUI
@_spi(CmuxHostTransport) import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxExtensionKit
import ExtensionFoundation
import SwiftUI

/// Transitional mounts for native support views while their parent surfaces
/// are still being moved to AppKit controllers.

private struct CmuxPaneDropZoneEnvironmentKey: EnvironmentKey {
    static let defaultValue: DropZone? = nil
}

extension EnvironmentValues {
    var paneDropZone: DropZone? {
        get { self[CmuxPaneDropZoneEnvironmentKey.self] }
        set { self[CmuxPaneDropZoneEnvironmentKey.self] = newValue }
    }
}

@MainActor
private final class BonsplitSwiftUIProviderBox<Content: View, EmptyContent: View> {
    var content: (Bonsplit.Tab, PaneID) -> Content
    var emptyPane: (PaneID) -> EmptyContent

    init(
        content: @escaping (Bonsplit.Tab, PaneID) -> Content,
        emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.content = content
        self.emptyPane = emptyPane
    }
}

@MainActor
private final class BonsplitSwiftUIContentController: NSHostingController<AnyView>,
    BonsplitContentUpdating,
    BonsplitPaneDropZoneReceiving
{
    private var tab: Bonsplit.Tab?
    private var pane: PaneID?
    private var dropZone: DropZone?
    private let render: @MainActor (Bonsplit.Tab, PaneID, DropZone?) -> AnyView

    init(
        tab: Bonsplit.Tab,
        pane: PaneID,
        render: @escaping @MainActor (Bonsplit.Tab, PaneID, DropZone?) -> AnyView
    ) {
        self.tab = tab
        self.pane = pane
        self.render = render
        super.init(rootView: render(tab, pane, nil))
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateBonsplitContent(tab: Bonsplit.Tab, pane: PaneID) {
        self.tab = tab
        self.pane = pane
        rootView = render(tab, pane, dropZone)
    }

    func bonsplitPaneDropZoneDidChange(_ zone: DropZone?) {
        dropZone = zone
        guard let tab, let pane else { return }
        rootView = render(tab, pane, zone)
    }
}

@MainActor
private final class BonsplitSwiftUIEmptyController: NSHostingController<AnyView> {
    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Temporary SwiftUI mount for Bonsplit's AppKit controller. The split and tab
/// hierarchy is native; only host-supplied cmux content remains hosted here.
struct BonsplitView<Content: View, EmptyContent: View>: NSViewControllerRepresentable {
    let controller: BonsplitController
    let content: (Bonsplit.Tab, PaneID) -> Content
    let emptyPane: (PaneID) -> EmptyContent

    init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Bonsplit.Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.content = content
        self.emptyPane = emptyPane
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, emptyPane: emptyPane)
    }

    func makeNSViewController(context: Context) -> BonsplitViewController {
        context.coordinator.makeViewController(controller: controller)
    }

    func updateNSViewController(_ viewController: BonsplitViewController, context: Context) {
        context.coordinator.providers.content = content
        context.coordinator.providers.emptyPane = emptyPane
        context.coordinator.update(viewController)
    }

    @MainActor
    final class Coordinator {
        private let providers: BonsplitSwiftUIProviderBox<Content, EmptyContent>

        init(
            content: @escaping (Bonsplit.Tab, PaneID) -> Content,
            emptyPane: @escaping (PaneID) -> EmptyContent
        ) {
            providers = BonsplitSwiftUIProviderBox(content: content, emptyPane: emptyPane)
        }

        func makeViewController(controller: BonsplitController) -> BonsplitViewController {
            BonsplitViewController(
                controller: controller,
                content: contentProvider(),
                emptyPane: emptyProvider()
            )
        }

        func update(_ viewController: BonsplitViewController) {
            viewController.updateProviders(
                content: contentProvider(),
                emptyPane: emptyProvider()
            )
        }

        private func contentProvider() -> BonsplitViewController.ContentProvider {
            { [weak providers] tab, pane in
                BonsplitSwiftUIContentController(tab: tab, pane: pane) { [weak providers] tab, pane, zone in
                    guard let providers else { return AnyView(EmptyView()) }
                    return AnyView(providers.content(tab, pane).environment(\.paneDropZone, zone))
                }
            }
        }

        private func emptyProvider() -> BonsplitViewController.EmptyPaneProvider {
            { [weak providers] pane in
                guard let providers else {
                    return BonsplitSwiftUIEmptyController(rootView: AnyView(EmptyView()))
                }
                return BonsplitSwiftUIEmptyController(rootView: AnyView(providers.emptyPane(pane)))
            }
        }
    }
}

extension WindowChromeColorScheme {
    var transitionalColorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

extension ColorScheme {
    var nativeWindowChromeColorScheme: WindowChromeColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        @unknown default: .dark
        }
    }
}

struct NativeWindowBackdropLayer: NSViewRepresentable {
    let role: WindowBackdropRole
    let snapshot: WindowAppearanceSnapshot

    func makeNSView(context: Context) -> WindowBackdropLayer {
        WindowBackdropLayer(role: role, snapshot: snapshot)
    }

    func updateNSView(_ view: WindowBackdropLayer, context: Context) {
        view.update(role: role, snapshot: snapshot)
    }
}

struct NativeWindowChromeBorder: NSViewRepresentable {
    let orientation: WindowChromeBorderOrientation
    var ignoresSafeArea = true
    var refreshNotificationName: Notification.Name?
    let backgroundColorProvider: @MainActor () -> NSColor

    func makeNSView(context: Context) -> WindowChromeBorder {
        WindowChromeBorder(
            orientation: orientation,
            ignoresSafeArea: ignoresSafeArea,
            refreshNotificationName: refreshNotificationName,
            backgroundColorProvider: backgroundColorProvider
        )
    }

    func updateNSView(_ view: WindowChromeBorder, context: Context) {
        view.refresh()
    }
}

struct NativeResolvedIconImage: NSViewRepresentable {
    let request: CmuxResolvedIconRequest?

    func makeNSView(context: Context) -> CmuxResolvedIconImage {
        CmuxResolvedIconImage(request: request)
    }

    func updateNSView(_ view: CmuxResolvedIconImage, context: Context) {
        view.apply(request)
    }
}

struct NativeSidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    init(_ onResolve: @escaping (NSScrollView?) -> Void) {
        self.onResolve = onResolve
    }

    func makeNSView(context: Context) -> SidebarScrollViewResolver {
        SidebarScrollViewResolver(onResolve: onResolve)
    }

    func updateNSView(_ view: SidebarScrollViewResolver, context: Context) {
        view.onResolve = onResolve
        view.resolveScrollView()
    }
}

struct NativeScrollBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollBackgroundClearer {
        ScrollBackgroundClearer(frame: .zero)
    }

    func updateNSView(_ view: ScrollBackgroundClearer, context: Context) {}
}

struct NativeBrowserSearchOverlayBridge: NSViewRepresentable {
    let panelId: UUID
    let searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void

    func makeNSView(context: Context) -> BrowserSearchOverlay {
        BrowserSearchOverlay(
            panelId: panelId,
            searchState: searchState,
            focusRequestGeneration: focusRequestGeneration,
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onFieldDidFocus: onFieldDidFocus
        )
    }

    func updateNSView(_ view: BrowserSearchOverlay, context: Context) {
        view.update(
            panelId: panelId,
            searchState: searchState,
            focusRequestGeneration: focusRequestGeneration,
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onFieldDidFocus: onFieldDidFocus
        )
    }
}

struct NativeOmnibarSuggestionsBridge: NSViewRepresentable {
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let colorScheme: WindowChromeColorScheme
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void

    func makeNSView(context: Context) -> OmnibarSuggestionsView {
        OmnibarSuggestionsView(
            engineName: engineName,
            items: items,
            selectedIndex: selectedIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: searchSuggestionsEnabled,
            colorScheme: colorScheme,
            onCommit: onCommit,
            onHighlight: onHighlight
        )
    }

    func updateNSView(_ view: OmnibarSuggestionsView, context: Context) {
        view.update(
            engineName: engineName,
            items: items,
            selectedIndex: selectedIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: searchSuggestionsEnabled,
            colorScheme: colorScheme,
            onCommit: onCommit,
            onHighlight: onHighlight
        )
    }
}

@available(macOS 14.0, *)
struct NativeSidebarExtensionHostBridge: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    let presentation: CmuxSidebarPresentation?
    var onConnection: (@MainActor (NSXPCConnection) -> Void)?
    var onDeactivation: (@MainActor ((any Error)?) -> Void)?
    var onTeardown: (@MainActor () -> Void)?
    var onPresentationAction: (@MainActor (String) -> Void)?

    func makeNSViewController(context: Context) -> CMUXSidebarExtensionHostView {
        CMUXSidebarExtensionHostView(
            identity: identity,
            presentation: presentation,
            onConnection: onConnection,
            onDeactivation: onDeactivation,
            onTeardown: onTeardown,
            onPresentationAction: onPresentationAction
        )
    }

    func updateNSViewController(
        _ viewController: CMUXSidebarExtensionHostView,
        context: Context
    ) {
        viewController.update(
            identity: identity,
            presentation: presentation,
            onConnection: onConnection,
            onDeactivation: onDeactivation,
            onTeardown: onTeardown,
            onPresentationAction: onPresentationAction
        )
    }

    static func dismantleNSViewController(
        _ viewController: CMUXSidebarExtensionHostView,
        coordinator: ()
    ) {
        viewController.teardown()
    }
}

struct NativeTitlebarLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat
    let baseLeadingInset: @MainActor () -> CGFloat

    func makeNSView(context: Context) -> TitlebarLeadingInsetReader {
        TitlebarLeadingInsetReader(
            baseLeadingInset: baseLeadingInset,
            onInsetChange: { inset = $0 }
        )
    }

    func updateNSView(_ view: TitlebarLeadingInsetReader, context: Context) {
        view.baseLeadingInset = baseLeadingInset
        view.onInsetChange = { inset = $0 }
        view.resolveInset()
    }
}

struct NativeArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let detachedGap: CGFloat
    @ViewBuilder let content: () -> PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> ArrowlessPopoverAnchor {
        let coordinator = context.coordinator
        coordinator.updateRootView(AnyView(content()))
        return ArrowlessPopoverAnchor(
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            detachedGap: detachedGap,
            contentViewController: coordinator.hostingController,
            onPresentationChange: { coordinator.isPresented.wrappedValue = $0 }
        )
    }

    func updateNSView(_ view: ArrowlessPopoverAnchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        let rootView = AnyView(content())
        if view.isPopoverShown {
            coordinator.visibleUpdateScheduler.schedule { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                coordinator.updateRootView(rootView)
                view.update(
                    isPresented: coordinator.isPresented.wrappedValue,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap,
                    contentViewController: coordinator.hostingController
                )
            }
        } else {
            coordinator.visibleUpdateScheduler.cancel()
            if isPresented { coordinator.updateRootView(rootView) }
        }
        view.update(
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            detachedGap: detachedGap,
            contentViewController: coordinator.hostingController
        )
    }

    static func dismantleNSView(_ view: ArrowlessPopoverAnchor, coordinator: Coordinator) {
        coordinator.visibleUpdateScheduler.cancel()
        view.dismiss()
    }

    @MainActor
    final class Coordinator {
        var isPresented: Binding<Bool>
        let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            CmuxPopoverMutation.performWithoutImplicitAnimation {
                hostingController.rootView = AnyView(rootView.fixedSize())
                hostingController.view.invalidateIntrinsicContentSize()
                hostingController.view.layoutSubtreeIfNeeded()
            }
        }
    }
}
