import AppKit
import Foundation
import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    @ObservedObject var model: UpdateViewModel
    @State private var showPopover = false

    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        if model.showsPill {
            pillButton
                .background(UpdatePillPopoverAnchor(isPresented: $showPopover, model: model))
                .onChange(of: model.showsPill) { _, showsPill in
                    if !showsPill {
                        showPopover = false
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var pillButton: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                UpdateBadge(model: model)
                    .frame(width: 14, height: 14)

                Text(model.text)
                    .font(Font(textFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: textWidth, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(model.foregroundColor)
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
                AppDelegate.shared?.checkForUpdatesInCustomUI()
            }
            return
        }

        if case .notFound(let notFound) = model.state {
            model.state = .idle
            notFound.acknowledgement()
        } else {
            showPopover.toggle()
        }
    }

    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (model.maxWidthText as NSString).size(withAttributes: attributes)
        return size.width
    }
}

private struct UpdatePillPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ObservedObject var model: UpdateViewModel

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
                UpdatePopoverView(model: model) {
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

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool

        weak var anchorView: NSView?
        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            hostingController.rootView = rootView
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            updateContentSize()
        }

        func present() {
            guard let anchorView, anchorView.window != nil else {
                isPresented = false
                dismiss()
                return
            }

            anchorView.superview?.layoutSubtreeIfNeeded()
            let popover = popover ?? makePopover()
            updateContentSize()
            guard !popover.isShown else { return }

            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        }

        func dismiss() {
            popover?.performClose(nil)
        }

        func closeFromContent() {
            isPresented = false
            dismiss()
        }

        func popoverDidClose(_ notification: Notification) {
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

        private func updateContentSize() {
            let fittingSize = hostingController.view.fittingSize
            guard fittingSize.width > 0, fittingSize.height > 0 else { return }
            popover?.contentSize = NSSize(
                width: ceil(fittingSize.width),
                height: ceil(fittingSize.height)
            )
        }
    }
}

/// Menu item that shows "Install Update and Relaunch" when an update is ready.
struct InstallUpdateMenuItem: View {
    @ObservedObject var model: UpdateViewModel

    var body: some View {
        if model.state.isInstallable {
            Button(String(localized: "update.installAndRelaunch", defaultValue: "Install Update and Relaunch")) {
                model.state.confirm()
            }
        }
    }
}
