import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation
import SwiftUI

struct FeedInlineTextField: NSViewRepresentable {
    @Binding var text: String

    let focusRequest: Int?
    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let placement: FeedPlacement
    let focusScopeID: UUID
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: (() -> Void)?

    typealias Coordinator = FeedInlineTextFieldCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedInlineTextEditorView {
        let view = FeedInlineTextEditorView(frame: .zero)
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        view.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        view.textView.onSubmit = onSubmit
        configure(view)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: FeedInlineTextEditorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = nsView
        nsView.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        nsView.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        nsView.textView.onSubmit = onSubmit
        configure(nsView)

        if nsView.textView.string != text, !nsView.textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            nsView.refreshMetrics()
        }

        guard let window = nsView.window else { return }
        let isFirstResponder = window.firstResponder === nsView.textView
        if let focusRequest,
           focusRequest != context.coordinator.lastAppliedFocusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            if isEnabled {
                nsView.focusIfNeeded()
            } else if isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if focusRequest == nil {
            context.coordinator.lastAppliedFocusRequest = nil
            if !isEnabled, isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if !isEnabled, isFirstResponder {
            moveFocusToFeedHost(in: window)
        }
    }

    private func moveFocusToFeedHost(in window: NSWindow) {
        guard placement.usesRightSidebarFocusCoordinator else {
            window.makeFirstResponder(nil)
            return
        }
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .feed,
            focusFirstItem: false,
            preferredWindow: window
        ) == true {
            return
        }
        window.makeFirstResponder(nil)
    }

    private func configure(_ view: FeedInlineTextEditorView) {
        view.placeholder = placeholder
        view.textView.feedFocusScopeID = focusScopeID
        view.apply(font: font, isEnabled: isEnabled)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FeedInlineTextEditorView,
        context: Context
    ) -> CGSize? {
        nil
    }

    static func dismantleNSView(_ nsView: FeedInlineTextEditorView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.textView.onActivate = nil
        nsView.textView.onEscape = nil
        nsView.textView.onSubmit = nil
    }
}

/// Minimal wrapping HStack that flows its children into multiple rows.
