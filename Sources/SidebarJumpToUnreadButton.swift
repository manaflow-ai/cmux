import AppKit
import Combine
import SwiftUI

/// What the sidebar footer's Jump to Unread control shows for a given unread
/// count and configured shortcut. Kept separate from the view so the label,
/// tooltip and visibility rules are testable without hosting SwiftUI.
struct SidebarJumpToUnreadButtonPresentation: Equatable {
    /// A turn arrow reads as "go there"; straight down arrows read as download.
    static let systemName = "arrow.turn.down.right"
    static let maxShownCount = 99

    let label: String
    let helpText: String
    /// The badge text, nil when nothing is unread (the control is hidden then).
    let countText: String?
    /// The configured shortcut, always shown to teach it; nil when unbound.
    let shortcutText: String?

    var isVisible: Bool { countText != nil }

    static func resolve(unreadCount: Int, shortcut: StoredShortcut) -> SidebarJumpToUnreadButtonPresentation {
        let action = KeyboardShortcutSettings.Action.jumpToUnread
        let title = action.label
        return SidebarJumpToUnreadButtonPresentation(
            label: String(localized: "sidebar.jumpToUnread.button", defaultValue: "Jump to unread"),
            helpText: shortcut.isUnbound ? title : action.tooltip(title, shortcut: shortcut),
            countText: unreadCount > 0 ? (unreadCount > maxShownCount ? "\(maxShownCount)+" : "\(unreadCount)") : nil,
            shortcutText: shortcut.isUnbound ? nil : shortcut.displayString
        )
    }
}

extension View {
    /// Puts the Jump to Unread control on its own row above the footer row.
    func sidebarJumpToUnreadBar(presentationMode: WorkspacePresentationModeSettings.Mode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarJumpToUnreadButton(presentationMode: presentationMode, placement: .aboveFooter)
            HStack(spacing: 4) {
                frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 0, height: 22)
            }
        }
    }
}

/// The on-screen ⇧⌘U, shown only while something is unread. On hover the
/// count turns into the configured shortcut (to teach it) and a × follows;
/// one × click asks to confirm, a second hides it for good. The jump runs
/// `AppDelegate.jumpToLatestUnread()`, like the menu item and the shortcut.
/// Unread state is reduced to a deduplicated count here, so notification
/// churn re-renders only this view, and only when the count changes.
struct SidebarJumpToUnreadButton: View {
    /// Design variations under review; `sCentered` ships. Debug builds switch them
    /// from the control's context menu.
    enum Style: String, CaseIterable {
        /// Glass capsule centered on its own row above the sidebar footer.
        case sCentered
        /// The same capsule at the bottom center of the window, hosted in
        /// AppKit above the terminal portal (see `WindowOverlay`).
        case windowBottom

        var placement: Placement { self == .sCentered ? .aboveFooter : .windowBottom }
        var debugTitle: String { self == .sCentered ? "Debug: Style Sidebar Bottom Center" : "Debug: Style Window Bottom Center" }
    }

    /// Where an instance sits; each renders only the styles placed there.
    enum Placement { case aboveFooter, windowBottom }

    /// Mounts the window style from the main content area.
    static func windowBottom(isMinimalMode: Bool) -> WindowBottomInstaller { WindowBottomInstaller(isMinimalMode: isMinimalMode) }

    static let hiddenDefaultsKey = "sidebar.jumpToUnreadButton.hidden"
    static let styleDefaultsKey = "debug.sidebarJumpToUnreadButton.style"

    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let presentationMode: WorkspacePresentationModeSettings.Mode
    let placement: Placement
    @State private var unreadCount: Int
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var isHovered = false
    @State private var isCloseHovered = false
    /// After the first × click the capsule asks for a second one.
    @State private var isConfirmingHide = false
    @State private var showsHiddenNote = false
    @AppStorage(SidebarJumpToUnreadButton.hiddenDefaultsKey) private var isHiddenByUser = false
    @AppStorage(SidebarJumpToUnreadButton.styleDefaultsKey) private var styleRawValue = Style.sCentered.rawValue

    init(presentationMode: WorkspacePresentationModeSettings.Mode, placement: Placement) {
        self.presentationMode = presentationMode
        self.placement = placement
        _unreadCount = State(initialValue: TerminalNotificationStore.shared.notificationMenuSnapshot.unreadCount)
    }

    private var style: Style {
#if DEBUG
        Style(rawValue: styleRawValue) ?? .sCentered
#else
        .sCentered
#endif
    }

    private var presentation: SidebarJumpToUnreadButtonPresentation {
        let _ = keyboardShortcutSettingsObserver.revision
        return .resolve(unreadCount: unreadCount, shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread))
    }

    var body: some View {
        let resolved = presentation
        Group {
            if SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: presentationMode),
               resolved.isVisible, !isHiddenByUser, style.placement == placement {
                control(resolved)
                    .contextMenu { contextMenuItems }
                    .frame(maxWidth: placement == .aboveFooter ? .infinity : nil, alignment: .center)
                    .padding(.bottom, placement == .aboveFooter ? 8 : 0)
            } else if placement == .windowBottom, showsHiddenNote {
                // The window capsule stays up with the note in it, then goes.
                hiddenNote.padding(.horizontal, 12).frame(height: 28)
            } else {
                // Zero size also tells `WindowOverlay` to hide the capsule.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .overlay(alignment: .bottom) {
            if showsHiddenNote, placement == .aboveFooter {
                hiddenNote.offset(y: -8).transition(.opacity)
            }
        }
        .task(id: showsHiddenNote) {
            guard showsHiddenNote else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.2)) { showsHiddenNote = false }
        }
        .task(id: isConfirmingHide) {
            guard isConfirmingHide else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { isConfirmingHide = false }
        }
        .onReceive(TerminalNotificationStore.shared.$notificationMenuSnapshot.map(\.unreadCount).removeDuplicates()) { count in
            if unreadCount != count { unreadCount = count }
        }
    }

    /// At rest "↳ Jump to Unread (3)"; on hover "↳ Jump to Unread ⇧⌘U ×";
    /// after one × click "Click × again to not show again ×".
    private func control(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        let showsClose = isHovered || isConfirmingHide
        return HStack(spacing: 4) {
            Button {
                // While confirming, the text is a prompt, not the jump.
                guard !isConfirmingHide else { return }
                AppDelegate.shared?.jumpToLatestUnread()
            } label: {
                HStack(spacing: 6) {
                    if isConfirmingHide {
                        title(String(localized: "sidebar.jumpToUnread.confirmHide", defaultValue: "Click × again to not show again"))
                    } else {
                        let arrow = SidebarJumpToUnreadButtonPresentation.systemName
                        CmuxSystemSymbolImage(systemName: arrow, pointSize: 11, weight: .semibold, tint: cmuxAccent.color)
                        title(String(localized: "sidebar.jumpToUnread.title", defaultValue: "Jump to Unread"))
                        // Hovering swaps the count for the key that does the same thing.
                        if isHovered, let shortcutText = resolved.shortcutText {
                            Text(shortcutText).cmuxFont(size: 11).tracking(0.5).lineLimit(1)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        } else if let countText = resolved.countText {
                            Text(countText).cmuxFont(size: 9, weight: .semibold).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(cmuxAccent.color))
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, showsClose ? 0 : 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .safeHelp(resolved.helpText)
            .accessibilityLabel(resolved.label)
            .accessibilityValue(resolved.countText ?? "")
            .accessibilityIdentifier("SidebarJumpToUnreadButton")
            if showsClose {
                closeButton.padding(.trailing, 6).transition(.opacity)
            }
        }
        .fixedSize()
        .sidebarJumpToUnreadFloatingGlass(hovered: isHovered, drawsGlass: placement == .aboveFooter)
        .onHover { hovering in
            isHovered = hovering
            if !hovering { isConfirmingHide = false }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isConfirmingHide)
    }

    private func title(_ text: String) -> some View {
        Text(text).cmuxFont(size: 12, weight: .medium).foregroundStyle(Color(nsColor: .labelColor)).lineLimit(1)
    }

    /// First click asks to confirm; the second hides the control for good
    /// (Settings > Sidebar brings it back).
    private var closeButton: some View {
        Button {
            if isConfirmingHide {
                withAnimation(.easeOut(duration: 0.2)) {
                    isHiddenByUser = true
                    showsHiddenNote = true
                    isConfirmingHide = false
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { isConfirmingHide = true }
            }
        } label: {
            CmuxSystemSymbolImage(systemName: "xmark", pointSize: 8, weight: .bold, tint: Color(nsColor: .secondaryLabelColor))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .safeHelp(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
        .accessibilityLabel(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
    }

    private var hiddenNote: some View {
        Text(String(localized: "sidebar.jumpToUnread.hiddenNote", defaultValue: "Hidden. Turn it back on in Settings > Sidebar."))
            .cmuxFont(size: 11).foregroundStyle(Color(nsColor: .secondaryLabelColor)).fixedSize()
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button")) {
            isHiddenByUser = true
            showsHiddenNote = true
        }
#if DEBUG
        Divider()
        ForEach(Style.allCases, id: \.self) { candidate in
            Button(candidate.debugTitle) { styleRawValue = candidate.rawValue }
        }
#endif
    }
}

extension SidebarJumpToUnreadButton {
    /// The window style's mount point: hosts the capsule in its window's AppKit
    /// overlay layer while that style is selected. SwiftUI sits under the
    /// terminal portal, so terminals would draw over it, keep their I-beam
    /// and stay out of its glass.
    struct WindowBottomInstaller: NSViewRepresentable {
        let isMinimalMode: Bool
        @AppStorage(SidebarJumpToUnreadButton.styleDefaultsKey) private var styleRawValue = Style.sCentered.rawValue

        func makeNSView(context: Context) -> WindowAnchor { WindowAnchor() }

        func updateNSView(_ anchor: WindowAnchor, context: Context) {
#if DEBUG
            let isSelected = Style(rawValue: styleRawValue) == .windowBottom
#else
            let isSelected = false
#endif
            let mode: WorkspacePresentationModeSettings.Mode = isMinimalMode ? .minimal : .standard
            anchor.content = isSelected ? SidebarJumpToUnreadButton(presentationMode: mode, placement: .windowBottom) : nil
        }

        static func dismantleNSView(_ anchor: WindowAnchor, coordinator: ()) { anchor.content = nil }
    }

    final class WindowAnchor: NSView {
        var content: SidebarJumpToUnreadButton? { didSet { synchronize() } }
        private weak var overlay: WindowOverlay?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            synchronize()
        }

        private func synchronize() {
            let next = content == nil ? nil : window.map { WindowOverlay.controller(for: $0) }
            if overlay !== next { overlay?.remove() }
            overlay = next
            if let content { next?.show(content) }
        }
    }

    /// One per window: the capsule's hosting view, sized to it, on a glass or
    /// material backdrop 16 pt above the window content's bottom center, in the
    /// portal's overlay container right above every terminal and browser host
    /// (later overlays such as the command palette stay above it).
    @MainActor
    final class WindowOverlay {
        private static var associationKey: UInt8 = 0
        private static let bottomInset: CGFloat = 16

        static func controller(for window: NSWindow) -> WindowOverlay {
            if let existing = objc_getAssociatedObject(window, &associationKey) as? WindowOverlay { return existing }
            let created = WindowOverlay(window: window)
            objc_setAssociatedObject(window, &associationKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return created
        }

        private weak var window: NSWindow?
        private let chromeComposition = AppWindowChromeComposition()
        private let root = NSView()
        private let backdrop = WindowOverlay.makeBackdrop()
        private let clip = NSView()
        private var host: Host?
        private var unreadSubscription: AnyCancellable?
        private weak var observedReference: NSView?
        private var referenceObserver: NSObjectProtocol?
        private var isLayoutScheduled = false

        private init(window: NSWindow) {
            self.window = window
            root.wantsLayer = true
            root.layer?.shadowColor = NSColor.black.cgColor
            root.layer?.shadowOpacity = 0.24
            root.layer?.shadowRadius = 6
            root.layer?.shadowOffset = CGSize(width: 0, height: -2)
            clip.wantsLayer = true
            clip.clipsToBounds = true
            clip.layer?.masksToBounds = true
            clip.layer?.borderWidth = 0.5
            clip.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
            for view in [backdrop, clip] {
                view.autoresizingMask = [.width, .height]
                root.addSubview(view)
            }
        }

        deinit { if let referenceObserver { NotificationCenter.default.removeObserver(referenceObserver) } }

        func show(_ content: SidebarJumpToUnreadButton) {
            // Leading-aligned, so content wider than a not-yet-resized host
            // grows out of the trailing edge, under the clip.
            let rootView = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .cmuxAccentColorEnvironment().cmuxFontMagnificationEnvironment())
            if let host {
                host.rootView = rootView
            } else {
                let host = Host(rootView: rootView)
                host.sizingOptions = [.intrinsicContentSize]
                host.onIntrinsicSizeChange = { [weak self] in self?.scheduleLayout() }
                clip.addSubview(host)
                self.host = host
            }
            // A new count re-promotes even when the capsule's size holds.
            unreadSubscription = unreadSubscription ?? TerminalNotificationStore.shared.$notificationMenuSnapshot
                .map(\.unreadCount)
                .removeDuplicates()
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleLayout() } }
            scheduleLayout()
        }

        func remove() {
            unreadSubscription = nil
            host?.removeFromSuperview()
            host = nil
            root.removeFromSuperview()
            observeReference(nil)
        }

        /// SwiftUI reports size changes mid-update; lay out once, next turn.
        private func scheduleLayout() {
            guard !isLayoutScheduled else { return }
            isLayoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.isLayoutScheduled = false
                self?.layout(animated: true)
            }
        }

        private func layout(animated: Bool) {
            guard let window, let host, let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window)
            else { return root.removeFromSuperview() }
            let container = target.container
            let wasVisible = root.superview === container && !root.frame.isEmpty
            promoteAbovePortals(in: container, reference: target.reference)
            observeReference(target.reference)
            let size = host.intrinsicContentSize
            guard size.width > 0, size.height > 0 else {
                root.frame = .zero // Nothing to show: takes no clicks, draws nothing.
                return
            }
            let area = container.convert(target.reference.bounds, from: target.reference)
            let width = ceil(size.width), height = ceil(size.height)
            let frame = NSRect(
                x: (area.midX - width / 2).rounded(),
                y: container.isFlipped ? area.maxY - Self.bottomInset - height : area.minY + Self.bottomInset,
                width: width, height: height
            )
            host.frame = NSRect(origin: .zero, size: frame.size)
            let radius = height / 2
            clip.layer?.cornerRadius = radius
            backdrop.layer?.cornerRadius = radius
#if compiler(>=6.2)
            if #available(macOS 26.0, *) { (backdrop as? NSGlassEffectView)?.cornerRadius = radius }
#endif
            root.layer?.shadowPath = CGPath(roundedRect: host.frame, cornerWidth: min(radius, width / 2), cornerHeight: radius, transform: nil)
            guard root.frame != frame else { return }
            guard animated, wasVisible else { root.frame = frame; return }
            // The capsule eases to its new width; the host is already there.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.root.frame = frame
            }
        }

        /// Portal hosts install just above the content view and can be
        /// re-added as splits and workspaces change; stay above the topmost.
        private func promoteAbovePortals(in container: NSView, reference: NSView) {
            let siblings = container.subviews
            let portal = siblings.last { $0 is WindowTerminalHostView || $0 is WindowBrowserHostView }
                ?? (reference.superview === container ? reference : nil)
            let portalIndex = portal.flatMap { candidate in siblings.firstIndex { $0 === candidate } } ?? -1
            if let rootIndex = siblings.firstIndex(where: { $0 === root }), rootIndex > portalIndex { return }
            container.addSubview(root, positioned: .above, relativeTo: portal)
        }

        private func observeReference(_ reference: NSView?) {
            guard observedReference !== reference else { return }
            if let referenceObserver { NotificationCenter.default.removeObserver(referenceObserver) }
            referenceObserver = nil
            observedReference = reference
            guard let reference else { return }
            reference.postsFrameChangedNotifications = true
            referenceObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: reference, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout(animated: false) }
            }
        }

        /// Liquid Glass on macOS 26, a popover material before; both blur
        /// the terminal beneath now that they sit above it.
        private static func makeBackdrop() -> NSView {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) { return NSGlassEffectView() }
#endif
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            return effect
        }

        /// Never takes keyboard focus (the terminal stays first responder),
        /// takes the first click in an inactive window, and owns the cursor
        /// over the capsule: an arrow, not the terminal's I-beam beneath.
        private final class Host: NSHostingView<AnyView> {
            var onIntrinsicSizeChange: (() -> Void)?
            override var acceptsFirstResponder: Bool { false }
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
            override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
            override func invalidateIntrinsicContentSize() {
                super.invalidateIntrinsicContentSize()
                onIntrinsicSizeChange?()
            }
        }
    }
}

private extension View {
    /// Liquid Glass on macOS 26 (a material capsule before), hairline rim,
    /// soft shadow, brighter on hover. The window style's AppKit host draws
    /// its own glass, rim and shadow, so it only gets the hover fill here.
    @ViewBuilder
    func sidebarJumpToUnreadFloatingGlass(hovered: Bool, drawsGlass: Bool) -> some View {
        let hoverFill = Capsule().fill(Color.white.opacity(hovered ? 0.06 : 0)).allowsHitTesting(false)
        if drawsGlass {
            Group {
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    glassEffect(.regular, in: Capsule())
                } else {
                    background(.regularMaterial, in: Capsule())
                }
                #else
                background(.regularMaterial, in: Capsule())
                #endif
            }
            .overlay(hoverFill)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.24), radius: 6, y: 2)
        } else {
            overlay(hoverFill)
        }
    }
}
