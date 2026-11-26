public import SwiftUI
import CmuxFoundation
public import CmuxUpdater
import AppKit

/// A pill-shaped button that displays update status and provides access to update actions.
public struct UpdatePill: View {
    private let model: UpdateStateModel
    private let appearance: UpdateAppearance
    private let actions: any UpdateActionsHost
    @State private var showPopover = false
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    private var textFont: NSFont {
        GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
    }

    /// Creates the pill.
    ///
    /// - Parameters:
    ///   - model: The observable update state.
    ///   - accent: The host accent color used for "update available" emphasis.
    ///   - actions: The host that performs update actions the pill triggers.
    public init(model: UpdateStateModel, accent: Color, actions: any UpdateActionsHost) {
        self.model = model
        self.appearance = UpdateAppearance(accent: accent)
        self.actions = actions
    }

    public var body: some View {
        ZStack {
            if model.showsPill {
                pillButton
                    .background(UpdatePillPopoverAnchor(isPresented: $showPopover, model: model, actions: actions))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        // The pill's appear/dismiss animation lives here (the controller no longer wraps the
        // "no updates" auto-dismiss in withAnimation, keeping SwiftUI out of the domain layer).
        .animation(.easeInOut(duration: 0.25), value: model.showsPill)
        .onChange(of: model.showsPill) { _, showsPill in
            if !showsPill {
                showPopover = false
            }
        }
    }

    @ViewBuilder
    private var pillButton: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                UpdateBadge(model: model, appearance: appearance)
                    .frame(width: 14, height: 14)

                Text(model.text)
                    .cmuxFont(size: 11, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: textWidth, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(appearance.backgroundColor(for: model))
            )
            .foregroundColor(appearance.foregroundColor(for: model))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .safeHelp(model.text)
        .accessibilityLabel(model.text)
        .accessibilityIdentifier("UpdatePill")
    }

    private func handleTap() {
        if model.showsDetectedBackgroundUpdate {
            if model.hasCachedDetectedUpdateDetails {
                showPopover.toggle()
            } else if showPopover {
                showPopover = false
            } else {
                showPopover = true
                actions.checkForUpdatesInCustomUI()
            }
            return
        }

        if case .notFound(let notFound) = model.state {
            model.setState(.idle)
            notFound.acknowledgement()
        } else {
            showPopover.toggle()
        }
    }

    private var textWidth: CGFloat? {
        _ = globalFontPercent
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (model.maxWidthText as NSString).size(withAttributes: attributes)
        return size.width
    }
}

struct UpdatePillPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let model: UpdateStateModel
    let actions: any UpdateActionsHost

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        context.coordinator.anchorView = nsView
        context.coordinator.updateRootView(
            AnyView(
                UpdatePopoverView(model: model, actions: actions) {
                    [weak coordinator] in
                    coordinator?.closeFromContent()
                }
            )
        )

        if isPresented {
            context.coordinator.present()
        } else {
            context.coordinator.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var visibleUpdateTask: Task<Void, Never>?
        var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            guard popover?.isShown == true else {
                cancelVisibleUpdate()
                applyRootView(rootView)
                return
            }
            // Leave the representable update before touching the shown popover; AppKit's
            // animated resize can otherwise re-enter SwiftUI's active view-graph update.
            visibleUpdateTask?.cancel()
            visibleUpdateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, self.popover?.isShown == true else { return }
                self.visibleUpdateTask = nil
                self.applyRootView(rootView)
            }
        }

        func present() {
            guard let anchorView, anchorView.window != nil else {
                isPresented = false
                dismiss()
                return
            }

            anchorView.superview?.layoutSubtreeIfNeeded()
            let popover = popover ?? makePopover()
            guard !popover.isShown else { return }
            updateContentSize()

            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        }

        func dismiss() {
            cancelVisibleUpdate()
            popover?.performClose(nil)
        }

        func closeFromContent() {
            isPresented = false
            dismiss()
        }

        func popoverDidClose(_ notification: Notification) {
            cancelVisibleUpdate()
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = true
            popover.contentViewController = hostingController
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func cancelVisibleUpdate() {
            visibleUpdateTask?.cancel()
            visibleUpdateTask = nil
        }

        private func applyRootView(_ rootView: AnyView) {
            performWithoutImplicitAnimation {
                hostingController.rootView = rootView
                hostingController.view.invalidateIntrinsicContentSize()
                hostingController.view.layoutSubtreeIfNeeded()
            }
            updateContentSize()
        }

        private func updateContentSize() {
            let fittingSize = hostingController.view.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }
            guard let popover else { return }
            let size = NSSize(
                width: ceil(fittingSize.width),
                height: ceil(fittingSize.height)
            )
            if popover.isShown {
                performWithoutImplicitAnimation {
                    popover.contentSize = size
                }
            } else {
                popover.contentSize = size
            }
        }

        private func performWithoutImplicitAnimation(_ body: () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                body()
            }
        }
    }
}

/// Menu item that shows "Install Update and Relaunch" when an update is ready.
public struct InstallUpdateMenuItem: View {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost

    /// Creates the menu item for `model`.
    public init(model: UpdateStateModel, actions: any UpdateActionsHost) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        if model.state.isInstallable {
            Button(String(localized: "update.installAndRelaunch", defaultValue: "Install Update and Relaunch")) {
                // Re-resolve to the latest available version before installing rather than
                // installing the version that was current when this menu item appeared (#6366).
                actions.attemptUpdate()
            }
        }
    }
}
