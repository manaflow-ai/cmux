import CmuxAppKitSupportUI
import SwiftUI

/// Transitional mounts for native support views while their parent surfaces
/// are still being moved to AppKit controllers.

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
