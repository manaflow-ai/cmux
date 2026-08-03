import Bonsplit
import AVKit
import CmuxAppKitSupportUI
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
@_spi(CmuxHostTransport) import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxExtensionKit
import ExtensionFoundation
import SwiftUI
import WebKit

extension StoredShortcut {
    var swiftUIKeyEquivalent: KeyEquivalent? {
        keyEquivalent.map(KeyEquivalent.init)
    }

    var swiftUIEventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if eventModifiers.contains(.command) { result.insert(.command) }
        if eventModifiers.contains(.shift) { result.insert(.shift) }
        if eventModifiers.contains(.option) { result.insert(.option) }
        if eventModifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

/// Transitional width observers used by the legacy root while the sidebar
/// layout itself is already stored with Observation.
struct SidebarWidthReader<Content: View>: View {
    @Bindable var layout: SidebarLayoutModel
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(layout.width)
    }
}

struct SidebarWidthFrameModifier: ViewModifier {
    @Bindable var layout: SidebarLayoutModel

    func body(content: Content) -> some View {
        content.frame(width: layout.width)
    }
}

struct SidebarWidthLeadingPaddingModifier: ViewModifier {
    @Bindable var layout: SidebarLayoutModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled ? layout.width : 0)
    }
}

/// Transitional mount for the native pointer event host while the root
/// workspace hierarchy is still hosted by the legacy renderer.
@MainActor
struct SidebarPointerEventHost: NSViewRepresentable {
    let onResolve: @MainActor (NSView) -> Void
    let onDismantle: @MainActor (NSView) -> Void

    init(
        _ onResolve: @escaping @MainActor (NSView) -> Void,
        onDismantle: @escaping @MainActor (NSView) -> Void
    ) {
        self.onResolve = onResolve
        self.onDismantle = onDismantle
    }

    func makeNSView(context: Context) -> SidebarPointerEventHostView {
        let view = SidebarPointerEventHostView()
        view.onResolve = onResolve
        view.onDismantle = onDismantle
        return view
    }

    func updateNSView(_ view: SidebarPointerEventHostView, context: Context) {
        view.onResolve = onResolve
        view.onDismantle = onDismantle
        view.resolve()
    }

    static func dismantleNSView(_ view: SidebarPointerEventHostView, coordinator: ()) {
        view.onDismantle?(view)
        view.onResolve = nil
        view.onDismantle = nil
    }
}

@MainActor
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    let dedupeByWindow: Bool
    let refreshID: AnyHashable?

    init(
        dedupeByWindow: Bool = true,
        refreshID: AnyHashable? = nil,
        onWindow: @escaping @MainActor (NSWindow) -> Void
    ) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
        self.refreshID = refreshID
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        installWindowHandler(on: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {
        installWindowHandler(on: view, coordinator: context.coordinator)
        if let window = view.window { view.onWindow?(window) }
    }

    private func installWindowHandler(on view: WindowObservingView, coordinator: Coordinator) {
        let handler = onWindow
        let shouldDedupeByWindow = dedupeByWindow
        let refreshID = refreshID
        view.onWindow = { window in
            guard coordinator.shouldInvoke(
                window: window,
                dedupeByWindow: shouldDedupeByWindow,
                refreshID: refreshID
            ) else { return }
            handler(window)
        }
    }

    final class Coordinator {
        private weak var lastWindow: NSWindow?
        private var lastRefreshID: AnyHashable?

        func shouldInvoke(
            window: NSWindow,
            dedupeByWindow: Bool,
            refreshID: AnyHashable?
        ) -> Bool {
            if dedupeByWindow, lastWindow === window, lastRefreshID == refreshID { return false }
            lastWindow = window
            lastRefreshID = refreshID
            return true
        }
    }
}

struct RightSidebarChromeGeometryReporter: NSViewRepresentable {
    var role: RightSidebarChromeGeometryRole
    var isVisible: Bool
    var titlebarHeight: CGFloat

    func makeNSView(context: Context) -> RightSidebarChromeGeometryReportingView {
        let view = RightSidebarChromeGeometryReportingView()
        update(view)
        return view
    }

    func updateNSView(_ view: RightSidebarChromeGeometryReportingView, context: Context) {
        update(view)
        view.reportIfNeeded()
    }

    private func update(_ view: RightSidebarChromeGeometryReportingView) {
        view.role = role
        view.isVisibleForReporting = isVisible
        view.titlebarHeight = titlebarHeight
    }
}

extension View {
    func reportRightSidebarChromeGeometryForBonsplitUITest(
        role: RightSidebarChromeGeometryRole = .modeBar,
        isVisible: Bool,
        titlebarHeight: CGFloat
    ) -> some View {
        background(
            RightSidebarChromeGeometryReporter(
                role: role,
                isVisible: isVisible,
                titlebarHeight: titlebarHeight
            )
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    func reportRightSidebarChromeNamedGeometryForBonsplitUITest(
        keyPrefix: String?,
        isVisible: Bool
    ) -> some View {
        if let keyPrefix {
            background(
                RightSidebarChromeGeometryReporter(
                    role: .named(keyPrefix),
                    isVisible: isVisible,
                    titlebarHeight: 0
                )
                .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}

struct TitlebarChromeGeometryReporter: NSViewRepresentable {
    let keyPrefix: String

    func makeNSView(context: Context) -> TitlebarChromeGeometryReportingView {
        let view = TitlebarChromeGeometryReportingView()
        view.keyPrefix = keyPrefix
        return view
    }

    func updateNSView(_ view: TitlebarChromeGeometryReportingView, context: Context) {
        view.keyPrefix = keyPrefix
        view.reportSoon()
    }
}

struct SidebarWorkspaceScrollEdgeFadeMask: NSViewRepresentable {
    let topHeight: CGFloat
    let bottomHeight: CGFloat

    func makeNSView(context: Context) -> SidebarWorkspaceScrollEdgeFadeMaskView {
        SidebarWorkspaceScrollEdgeFadeMaskView()
    }

    func updateNSView(_ view: SidebarWorkspaceScrollEdgeFadeMaskView, context: Context) {
        view.topHeight = topHeight
        view.bottomHeight = bottomHeight
    }
}

#if DEBUG
private struct MinimalModeInvalidationProbeKey: EnvironmentKey {
    static let defaultValue = MinimalModeInvalidationProbe()
}

private struct SidebarLazyContractProbeKey: EnvironmentKey {
    static let defaultValue = SidebarLazyContractProbe()
}

extension EnvironmentValues {
    var minimalModeInvalidationProbe: MinimalModeInvalidationProbe {
        get { self[MinimalModeInvalidationProbeKey.self] }
        set { self[MinimalModeInvalidationProbeKey.self] = newValue }
    }

    var sidebarLazyContractProbe: SidebarLazyContractProbe {
        get { self[SidebarLazyContractProbeKey.self] }
        set { self[SidebarLazyContractProbeKey.self] = newValue }
    }
}
#endif

enum SidebarTitleFirstLineCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    static let sidebarTitleFirstLineCenter = VerticalAlignment(
        SidebarTitleFirstLineCenterAlignment.self
    )
}

extension View {
    @ViewBuilder
    func sidebarRowDragGate(
        isEditing: Bool,
        _ makeProvider: @escaping () -> NSItemProvider
    ) -> some View {
        if isEditing { self } else { onDrag(makeProvider) }
    }
}

struct MinimalModeTitlebarEventSurfaceLayer: View {
    let isFullScreen: Bool
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var body: some View {
        MinimalModeTitlebarEventSurfaceView(
            isEnabled: WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
                && !isFullScreen
        )
    }
}

struct WorkspaceContentMinimalModeSafeAreaModifier: ViewModifier {
    let isFullScreen: Bool
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    func body(content: Content) -> some View {
        let isMinimal = WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
        content.ignoresSafeArea(.container, edges: (isMinimal && !isFullScreen) ? .top : [])
    }
}

struct WorkspaceTitlebarModeLayer<Titlebar: View>: View {
    let titlebar: () -> Titlebar
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var body: some View {
        if WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) != .minimal {
            titlebar()
        }
    }
}

private struct CanvasInlineBrowserHostingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cmuxCanvasInlineBrowserHosting: Bool {
        get { self[CanvasInlineBrowserHostingKey.self] }
        set { self[CanvasInlineBrowserHostingKey.self] = newValue }
    }
}

struct TitlebarInteractiveControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TitlebarInteractiveControlRegion())
    }
}

extension View {
    func titlebarInteractiveControl() -> some View {
        modifier(TitlebarInteractiveControlModifier())
    }
}

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let titlebarPadding: CGFloat
    let hostingSafeAreaTop: CGFloat
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    func body(content: Content) -> some View {
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        ))
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum InternalTabDragConfigurationProvider {
    static let value = DragConfiguration(
        operationsWithinApp: .init(allowCopy: false, allowMove: true, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: false, allowMove: false, allowDelete: false)
    )
}
#endif

private struct InternalTabDragConfigurationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.dragConfiguration(InternalTabDragConfigurationProvider.value)
        } else {
            content
        }
#else
        content
#endif
    }
}

extension View {
    func internalOnlyTabDrag() -> some View {
        modifier(InternalTabDragConfigurationModifier())
    }
}

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

/// Keeps transitional SwiftUI roots synchronized with the native appearance
/// source of truth while those roots are being removed.
private struct AppearanceColorSchemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemAppearanceGeneration = 0
    let rawValue: String?

    func body(content: Content) -> some View {
        let override = AppearanceSettings.colorSchemeOverride(for: rawValue)
        let _ = systemAppearanceGeneration
        let effective = AppearanceSettings.effectiveColorScheme(
            for: rawValue,
            fallback: colorScheme.nativeWindowChromeColorScheme
        )
        content
            .environment(\.colorScheme, effective.transitionalColorScheme)
            .preferredColorScheme(override?.transitionalColorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .systemAppearanceDidChange)) { _ in
                systemAppearanceGeneration &+= 1
            }
    }
}

extension View {
    func cmuxAppearanceColorScheme(_ rawValue: String?) -> some View {
        modifier(AppearanceColorSchemeModifier(rawValue: rawValue))
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

struct NativeAccountSignInViewBridge: NSViewRepresentable {
    let model: AccountSignInModel
    let automaticallyStartsSignIn: Bool

    func makeNSView(context: Context) -> AccountSignInView {
        AccountSignInView(
            model: model,
            automaticallyStartsSignIn: automaticallyStartsSignIn
        )
    }

    func updateNSView(_ view: AccountSignInView, context: Context) {}
}

struct NativeStackAccountAvatarBridge: NSViewRepresentable {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let size: CGFloat
    let loadingSystemName: String?

    func makeNSView(context: Context) -> StackAccountAvatarView {
        StackAccountAvatarView(
            avatarURL: avatarURL,
            displayName: displayName,
            email: email,
            size: size,
            loadingSystemName: loadingSystemName
        )
    }

    func updateNSView(_ view: StackAccountAvatarView, context: Context) {
        view.update(avatarURL: avatarURL, displayName: displayName, email: email)
    }
}

struct NativeMobilePairingViewBridge: NSViewRepresentable {
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> MobilePairingView {
        MobilePairingView(
            backgroundColor: backgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    func updateNSView(_ view: MobilePairingView, context: Context) {
        view.updatePresentation(
            backgroundColor: backgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
}

struct MobilePairingPanelView: View {
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        NativeMobilePairingViewBridge(
            backgroundColor: appearance.contentBackgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
        .accessibilityIdentifier("MobilePairingPanel")
    }
}

struct AccountSignInPanelView: View {
    let panel: AccountSignInPanel
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ScrollView {
            NativeAccountSignInViewBridge(model: panel.model, automaticallyStartsSignIn: true)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
        .accessibilityIdentifier("AccountSignInPanel")
    }
}

struct SidebarProBadge: View {
    var body: some View { NativeProBadgeViewBridge() }
}

struct SimulatorFocusOwnershipBridge: NSViewRepresentable {
    let panel: SimulatorPanel

    func makeNSView(context: Context) -> SimulatorFocusOwnershipView {
        let view = SimulatorFocusOwnershipView()
        view.update(panel: panel)
        return view
    }

    func updateNSView(_ view: SimulatorFocusOwnershipView, context: Context) {
        view.update(panel: panel)
    }

    static func dismantleNSView(_ view: SimulatorFocusOwnershipView, coordinator: Void) {
        view.teardown()
    }
}

struct HoverTrackingRepresentable: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onChange: onChange)
    }

    func updateNSView(_ view: HoverTrackingNSView, context: Context) {
        view.onChange = onChange
    }
}

struct ResizeGripperRepresentable: NSViewRepresentable {
    let onBegin: () -> (CGFloat, CGFloat)
    let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> ResizeGripperNSView {
        ResizeGripperNSView()
    }

    func updateNSView(_ view: ResizeGripperNSView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

struct GPUSpinner: NSViewRepresentable {
    let style: GPUSpinnerStyle
    let color: NSColor

    func makeNSView(context: Context) -> GPUSpinnerNSView {
        let view = GPUSpinnerNSView(frame: .zero)
        view.style = style
        view.color = color
        return view
    }

    func updateNSView(_ view: GPUSpinnerNSView, context: Context) {
        view.style = style
        view.color = color
    }
}

struct FilePreviewImageView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewImageContainerView {
        panel.nativeViewSessions.image.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: FilePreviewImageContainerView, context: Context) {
        panel.nativeViewSessions.image.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

struct FilePreviewPDFView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewPDFContainerView {
        panel.nativeViewSessions.pdf.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: FilePreviewPDFContainerView, context: Context) {
        panel.nativeViewSessions.pdf.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

struct FilePreviewMediaView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        panel.nativeViewSessions.media.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        panel.nativeViewSessions.media.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

struct SessionIndexTableView: NSViewRepresentable {
    let rows: [SessionIndexTableRow]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent

    func makeCoordinator() -> SessionIndexTableController { SessionIndexTableController() }

    func makeNSView(context: Context) -> SessionIndexTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ view: SessionIndexTableContainerView, context: Context) {
        context.coordinator.apply(
            rows: rows,
            environment: SessionIndexTableEnvironmentSnapshot(
                colorScheme: colorScheme == .dark ? .dark : .light,
                globalFontMagnificationPercent: globalFontMagnificationPercent
            )
        )
    }

    static func dismantleNSView(
        _ view: SessionIndexTableContainerView,
        coordinator: SessionIndexTableController
    ) {
        coordinator.dismantle()
    }
}

struct NativeFeedbackComposerBridge: NSViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeNSViewController(context: Context) -> SidebarFeedbackComposerSheet {
        let coordinator = context.coordinator
        return SidebarFeedbackComposerSheet { coordinator.dismiss() }
    }

    func updateNSViewController(
        _ viewController: SidebarFeedbackComposerSheet,
        context: Context
    ) {
        context.coordinator.dismissAction = dismiss
    }

    @MainActor
    final class Coordinator {
        var dismissAction: DismissAction
        init(dismiss: DismissAction) { dismissAction = dismiss }
        func dismiss() { dismissAction() }
    }
}

struct NativeCustomSidebarSurfaceBridge: NSViewRepresentable {
    let fileURL: URL
    let dataContext: [String: SwiftValue]
    let dispatch: SidebarActionDispatch
    let contentInsets: CustomSidebarContentInsets
    let rendersInProcess: Bool
    let clientStore: RenderWorkerClientStore

    func makeNSView(context: Context) -> CustomSidebarSurface {
        CustomSidebarSurface(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess,
            clientStore: clientStore
        )
    }

    func updateNSView(_ view: CustomSidebarSurface, context: Context) {
        view.update(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess
        )
    }

    static func dismantleNSView(_ view: CustomSidebarSurface, coordinator: ()) {
        view.teardown()
    }
}

struct SidebarWorkspaceTableView: NSViewRepresentable {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    let isPresented: Bool
    let unreadSource: SidebarUnreadModel

#if DEBUG
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    func makeCoordinator() -> SidebarWorkspaceTableController { SidebarWorkspaceTableController() }

    func makeNSView(context: Context) -> SidebarWorkspaceTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ view: SidebarWorkspaceTableContainerView, context: Context) {
#if DEBUG
        context.coordinator.reconfigurationProbe = sidebarLazyContractProbe.tableRootViewReconfigure
#endif
        context.coordinator.setUnreadSource(unreadSource)
        context.coordinator.setPresentationActive(isPresented, workspaceIds: workspaceIds)
        guard isPresented else { return }
        context.coordinator.apply(
            rows: rows,
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
        )
    }

    static func dismantleNSView(
        _ view: SidebarWorkspaceTableContainerView,
        coordinator: SidebarWorkspaceTableController
    ) {
        coordinator.dismantleContainerView(view)
    }
}

struct QuickLookPreviewView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeCoordinator() -> FilePreviewQuickLookViewCoordinator {
        FilePreviewQuickLookViewCoordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSView {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        return quickLook.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: NSView, context: Context) {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        quickLook.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: FilePreviewQuickLookViewCoordinator) {
        coordinator.quickLook?.dismantle(view)
        coordinator.quickLook = nil
    }
}

struct AgentSessionWebRenderer: NSViewRepresentable {
    let panel: AgentSessionPanel
    let isFocused: Bool
    let backgroundColor: NSColor
    let theme: AgentSessionWebTheme
    let sessionContentWidthPresentation: SessionContentWidthPresentation
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> AgentSessionWebRendererCoordinator {
        panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.currentProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
    }

    func makeNSView(context: Context) -> NSView {
        let host = AgentSessionWebHostView()
        host.wantsLayer = true
        applyBackground(to: host)
        return host
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let host = view as? AgentSessionWebHostView else { return }
        context.coordinator.bind(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            rendererKind: panel.rendererKind,
            initialProviderID: panel.currentProviderID,
            workingDirectory: panel.workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        let webView = context.coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.onPointerDown = onRequestPanelFocus
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        applyBackground(to: host)
        applyBackground(to: webView)
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance { webView.appearance = appearance }
        host.setSessionContentWidthPresentation(sessionContentWidthPresentation)
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.loadShellIfNeeded()
            coordinator?.flushVisiblePaintIfReady()
        }
        host.onGeometryChanged = { [weak coordinator = context.coordinator] in
            coordinator?.flushVisiblePaintIfReady()
        }
        context.coordinator.loadShellIfNeeded()
        context.coordinator.flushVisiblePaintIfReady()
        if isFocused { context.coordinator.focus() }
    }

    static func dismantleNSView(_ view: NSView, coordinator: AgentSessionWebRendererCoordinator) {
        guard let host = view as? AgentSessionWebHostView else { return }
        host.detachHostedWebViewIfOwned(coordinator.webView)
        host.onDidMoveToWindow = nil
        host.onGeometryChanged = nil
    }

    private func applyBackground(to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
        view.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        applyBackground(to: webView as NSView)
    }
}

@MainActor
struct BrowserOmnibarInteractionRepresentable: NSViewRepresentable {
    let panelId: UUID

    func makeNSView(context: Context) -> BrowserOmnibarInteractionView {
        let view = BrowserOmnibarInteractionView(frame: .zero)
        view.panelId = panelId
        return view
    }

    func updateNSView(_ view: BrowserOmnibarInteractionView, context: Context) {
        view.panelId = panelId
        view.window?.invalidateCursorRects(for: view)
    }
}

extension GhosttyTerminalView {
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? max(1, nsView.bounds.width),
            height: proposal.height ?? max(1, nsView.bounds.height)
        )
    }
}

struct SidebarAgentActivityIndicator: View {
    let spinnerColor: NSColor
    let side: CGFloat

    var body: some View {
        GPUSpinner(style: .macOSSpokes, color: spinnerColor)
            .frame(width: side, height: side)
            .fixedSize()
    }
}

struct SidebarWorkspaceLoadingSpinner: View {
    let side: CGFloat
    let color: NSColor
    let tooltip: String

    var body: some View {
        SidebarAgentActivityIndicator(spinnerColor: color, side: side)
            .safeHelp(tooltip)
            .accessibilityLabel(Text(tooltip))
    }
}

struct WorkspaceAttentionFlashRingView: NSViewRepresentable {
    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation

    func makeNSView(context: Context) -> WorkspaceAttentionFlashRingNativeView {
        let view = WorkspaceAttentionFlashRingNativeView(frame: .zero)
        view.update(opacity: opacity, reason: reason)
        return view
    }

    func updateNSView(_ view: WorkspaceAttentionFlashRingNativeView, context: Context) {
        view.update(opacity: opacity, reason: reason)
    }
}

struct SimulatorFeatureDisabledView: NSViewRepresentable {
    let panel: SimulatorPanel
    let appearance: PanelAppearance

    func makeNSView(context: Context) -> SimulatorFeatureDisabledNativeView {
        _ = panel
        return SimulatorFeatureDisabledNativeView(
            backgroundColor: appearance.contentBackgroundColor
        )
    }

    func updateNSView(_ view: SimulatorFeatureDisabledNativeView, context: Context) {
        _ = panel
        view.update(backgroundColor: appearance.contentBackgroundColor)
    }
}

struct DockUnreadProjectionContextBridge: NSViewRepresentable {
    let projection: DockUnreadPanelProjection
    let panelIDs: Set<UUID>
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        projection.updateContext(panelIDs: panelIDs, isActive: isActive)
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        projection.updateContext(panelIDs: panelIDs, isActive: isActive)
    }
}

struct WorkspacePresentationModeChangeObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WorkspacePresentationModeObserverView {
        WorkspacePresentationModeObserverView(onChange: onChange)
    }

    func updateNSView(_ view: WorkspacePresentationModeObserverView, context: Context) {
        view.onChange = onChange
        view.publishIfChanged()
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

struct NativeProBadgeViewBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ProBadgeView {
        ProBadgeView(frame: .zero)
    }

    func updateNSView(_ view: ProBadgeView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ProBadgeView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct NativeProBadgeLabelBridge: NSViewRepresentable {
    let style: ProBadgeStyle

    func makeNSView(context: Context) -> ProBadgeLabelView {
        ProBadgeLabelView(style: style)
    }

    func updateNSView(_ view: ProBadgeLabelView, context: Context) {
        view.update(style: style)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ProBadgeLabelView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
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
