import AppKit
import SwiftUI

struct GlobalSearchKeyboardFocusAnchor: NSViewRepresentable {
    final class Coordinator {
        var placement: GlobalSearchSurfacePlacement
        var onViewChange: (GlobalSearchKeyboardFocusView?) -> Void
        var onFocusSearchField: () -> Bool
        var ownsSearchFieldFocus: () -> Bool
        weak var attachedView: GlobalSearchKeyboardFocusView?

        init(
            placement: GlobalSearchSurfacePlacement,
            onViewChange: @escaping (GlobalSearchKeyboardFocusView?) -> Void,
            onFocusSearchField: @escaping () -> Bool,
            ownsSearchFieldFocus: @escaping () -> Bool
        ) {
            self.placement = placement
            self.onViewChange = onViewChange
            self.onFocusSearchField = onFocusSearchField
            self.ownsSearchFieldFocus = ownsSearchFieldFocus
        }

        func attach(_ view: GlobalSearchKeyboardFocusView) {
            view.placement = placement
            view.onFocusSearchField = onFocusSearchField
            view.ownsSearchFieldFocus = ownsSearchFieldFocus
            guard attachedView !== view else { return }
            attachedView = view
            onViewChange(view)
        }

        func detach(_ view: GlobalSearchKeyboardFocusView) {
            guard attachedView === view else { return }
            attachedView = nil
            onViewChange(nil)
        }
    }

    let placement: GlobalSearchSurfacePlacement
    var onViewChange: (GlobalSearchKeyboardFocusView?) -> Void
    var onFocusSearchField: () -> Bool
    var ownsSearchFieldFocus: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            placement: placement,
            onViewChange: onViewChange,
            onFocusSearchField: onFocusSearchField,
            ownsSearchFieldFocus: ownsSearchFieldFocus
        )
    }

    func makeNSView(context: Context) -> GlobalSearchKeyboardFocusView {
        let view = GlobalSearchKeyboardFocusView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: GlobalSearchKeyboardFocusView, context: Context) {
        context.coordinator.placement = placement
        context.coordinator.onViewChange = onViewChange
        context.coordinator.onFocusSearchField = onFocusSearchField
        context.coordinator.ownsSearchFieldFocus = ownsSearchFieldFocus
        context.coordinator.attach(nsView)
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    static func dismantleNSView(_ nsView: GlobalSearchKeyboardFocusView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }
}

final class GlobalSearchKeyboardFocusView: NSView {
    var placement: GlobalSearchSurfacePlacement = .rightSidebar
    var onFocusSearchField: (() -> Bool)?
    var ownsSearchFieldFocus: (() -> Bool)?
    private weak var registeredWindow: NSWindow?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard placement == .rightSidebar, let window else {
            registeredWindow = nil
            return
        }
        guard registeredWindow !== window else { return }
        registeredWindow = window
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerGlobalSearchHost(self)
    }

    func focusSearchFieldFromCoordinator() -> Bool {
        if onFocusSearchField?() == true {
            return true
        }
        guard let window else { return false }
        return window.makeFirstResponder(self)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        if ownsSearchFieldFocus?() == true, Self.isTextFieldEditor(responder) {
            return true
        }
        guard let responderView = Self.view(for: responder) else { return false }
        guard let root = focusRootView else { return false }
        return responderView === root || responderView.isDescendant(of: root)
    }

    private static func isTextFieldEditor(_ responder: NSResponder) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isFieldEditor
    }

    private static func view(for responder: NSResponder) -> NSView? {
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let delegateResponder = textView.delegate as? NSResponder,
           delegateResponder !== textView,
           let delegateView = view(for: delegateResponder) {
            return delegateView
        }

        var current: NSResponder? = responder
        while let candidate = current {
            if let view = candidate as? NSView {
                return view
            }
            current = candidate.nextResponder
        }
        return nil
    }

    private var focusRootView: NSView? {
        superview
    }
}
