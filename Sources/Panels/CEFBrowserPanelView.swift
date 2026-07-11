import AppKit
import CEFKit
import SwiftUI

struct CEFBrowserPanelView: View {
    @ObservedObject var panel: CEFBrowserPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    @FocusState private var isAddressFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    onRequestPanelFocus()
                    panel.goBack()
                } label: {
                    Label(
                        String(localized: "browser.goBack", defaultValue: "Go Back"),
                        systemImage: "chevron.left"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!panel.canGoBack)
                .help(String(localized: "browser.goBack", defaultValue: "Go Back"))

                Button {
                    onRequestPanelFocus()
                    panel.goForward()
                } label: {
                    Label(
                        String(localized: "browser.goForward", defaultValue: "Go Forward"),
                        systemImage: "chevron.right"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!panel.canGoForward)
                .help(String(localized: "browser.goForward", defaultValue: "Go Forward"))

                Button {
                    onRequestPanelFocus()
                    panel.reload()
                } label: {
                    Label(
                        String(localized: "browser.reload", defaultValue: "Reload"),
                        systemImage: "arrow.clockwise"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "browser.reload", defaultValue: "Reload"))

                TextField(
                    String(localized: "cef.browser.address.placeholder", defaultValue: "Enter URL"),
                    text: $panel.currentURL
                )
                .textFieldStyle(.roundedBorder)
                .focused($isAddressFieldFocused)
                .simultaneousGesture(TapGesture().onEnded {
                    panel.setAddressFieldFocused(true)
                    onRequestPanelFocus()
                })
                .onSubmit {
                    panel.navigate(to: panel.currentURL)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            CEFBrowserContainerRepresentable(
                containerView: panel.containerView,
                onRequestPanelFocus: onRequestPanelFocus
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    panel.start(url: panel.currentURL)
                }
        }
        .onChange(of: isAddressFieldFocused) { _, isFocused in
            panel.setAddressFieldFocused(isFocused)
        }
        .onChange(of: isFocused) { _, isFocused in
            if !isFocused {
                isAddressFieldFocused = false
            }
        }
    }
}

private struct CEFBrowserContainerRepresentable: NSViewRepresentable {
    let containerView: CEFBrowserContainerView
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(containerView: containerView, onRequestPanelFocus: onRequestPanelFocus)
    }

    func makeNSView(context: Context) -> CEFBrowserContainerView {
        containerView
    }

    func updateNSView(_ nsView: CEFBrowserContainerView, context: Context) {}

    @MainActor
    final class Coordinator {
        private weak var containerView: CEFBrowserContainerView?
        private let onRequestPanelFocus: () -> Void
        private var eventMonitor: Any?

        init(containerView: CEFBrowserContainerView, onRequestPanelFocus: @escaping () -> Void) {
            self.containerView = containerView
            self.onRequestPanelFocus = onRequestPanelFocus
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let containerView = self.containerView,
                      event.window === containerView.window,
                      !containerView.isHiddenOrHasHiddenAncestor,
                      self.eventTargetsContainer(event, containerView: containerView) else {
                    return event
                }

                self.onRequestPanelFocus()
                return event
            }
        }

        private func eventTargetsContainer(
            _ event: NSEvent,
            containerView: CEFBrowserContainerView
        ) -> Bool {
            guard let contentView = event.window?.contentView else { return false }
            let hitPoint = contentView.convert(event.locationInWindow, from: nil)
            var hitView = contentView.hitTest(hitPoint)
            while let view = hitView {
                if view === containerView {
                    return true
                }
                hitView = view.superview
            }
            return false
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }
}
