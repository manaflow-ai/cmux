import SwiftUI
import WebKit
import Bonsplit

/// SwiftUI view that renders a ChatPanel's WKWebView via NSViewRepresentable.
struct ChatPanelView: View {
    @ObservedObject var panel: ChatPanel
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        ChatWebViewRepresentable(panel: panel)
            .id(panel.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                    .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                    .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                    .padding(FocusFlashPattern.ringInset)
                    .allowsHitTesting(false)
            }
            .onTapGesture {
                onRequestPanelFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .webViewDidReceiveClick).filter { [weak panel] note in
                guard let webView = note.object as? CmuxWebView else { return false }
                return webView === panel?.webView
            }) { _ in
                if !isFocused {
                    onRequestPanelFocus()
                }
            }
            .onChange(of: panel.focusFlashToken) { _ in
                triggerFocusFlashAnimation()
            }
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        }
    }
}

// MARK: - NSViewRepresentable wrapper

/// Wraps the ChatPanel's CmuxWebView for hosting in SwiftUI.
private struct ChatWebViewRepresentable: NSViewRepresentable {
    let panel: ChatPanel

    private final class HostContainerView: NSView {
        weak var hostedWebView: WKWebView?
        var onDidMoveToWindow: (() -> Void)?
        var onScheduleAttachmentRecovery: (() -> Void)?
        private var attachmentRecoveryGeneration: Int = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
            layoutSubtreeIfNeeded()
            onDidMoveToWindow?()
            scheduleAttachmentRecovery()
        }

        func scheduleAttachmentRecovery() {
            attachmentRecoveryGeneration &+= 1
            let generation = attachmentRecoveryGeneration
            let retryDelays: [TimeInterval] = [0.0, 0.05, 0.15]
            for delay in retryDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.attachmentRecoveryGeneration == generation else { return }
                    self.onScheduleAttachmentRecovery?()
                }
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView()
        container.wantsLayer = true
        container.onDidMoveToWindow = { [weak container] in
            guard let container else { return }
            attachWebView(panel.webView, to: container)
        }
        container.onScheduleAttachmentRecovery = { [weak container] in
            guard let container else { return }
            attachWebView(panel.webView, to: container)
        }
        attachWebView(panel.webView, to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? HostContainerView else { return }
        container.onDidMoveToWindow = { [weak container] in
            guard let container else { return }
            attachWebView(panel.webView, to: container)
        }
        container.onScheduleAttachmentRecovery = { [weak container] in
            guard let container else { return }
            attachWebView(panel.webView, to: container)
        }
        attachWebView(panel.webView, to: container)
        if container.window != nil,
           (panel.webView.superview !== container || panel.webView.frame.isEmpty) {
            container.scheduleAttachmentRecovery()
        }
    }

    private func attachWebView(_ webView: WKWebView, to container: HostContainerView) {
        let shouldPreserveExistingVisibleHost =
            container.window == nil &&
            webView.superview != nil &&
            !(webView.superview === container || webView.isDescendant(of: container))
        if shouldPreserveExistingVisibleHost {
            return
        }

        let alreadyHostedInContainer =
            container.hostedWebView === webView &&
            webView.superview === container &&
            webView.frame.equalTo(container.bounds) &&
            webView.translatesAutoresizingMaskIntoConstraints
        if alreadyHostedInContainer {
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
            return
        }

        if let superview = webView.superview {
            NSLayoutConstraint.deactivate(
                superview.constraints.filter { constraint in
                    constraint.firstItem as AnyObject? === webView || constraint.secondItem as AnyObject? === webView
                }
            )
            webView.removeFromSuperview()
        }

        container.subviews
            .filter { $0 !== webView }
            .forEach { $0.removeFromSuperview() }

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        webView.frame = container.bounds
        container.hostedWebView = webView
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }
}
