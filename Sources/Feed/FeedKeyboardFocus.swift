import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

struct FeedStopDraft: Equatable {
    var reply = ""

    var isPristine: Bool {
        reply.isEmpty
    }
}

struct FeedRowSurface: View {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let isFocusActive: Bool
    let showsDivider: Bool
    @Binding var stopDraft: FeedStopDraft
    let placement: FeedPlacement
    let focusScopeID: UUID
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlAction: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void

    @State private var isHovered = false
    @State private var stopReplyFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            FeedItemRow(
                snapshot: snapshot,
                actions: actions,
                isSelected: isFocusActive,
                onPressSelect: onPressSelect,
                onControlFocus: onControlFocus,
                onControlAction: onControlAction,
                onControlBlur: onControlBlur,
                onActivate: onActivate,
                stopDraft: $stopDraft,
                stopDraftValue: stopDraft,
                stopFocusRequest: $stopReplyFocusRequest,
                stopFocusRequestValue: stopReplyFocusRequest,
                placement: placement,
                focusScopeID: focusScopeID
            )
            .equatable()
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackgroundFill)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackgroundFill: Color {
        if isSelected {
            guard isFocusActive else {
                return Color.primary.opacity(0.07)
            }
            if snapshot.status.isPending {
                return tint.opacity(0.14)
            }
            return Color.primary.opacity(0.075)
        }
        if isHovered {
            if snapshot.status.isPending {
                return tint.opacity(0.10)
            }
            return Color.primary.opacity(0.055)
        }
        return .clear
    }

    private var tint: Color {
        switch snapshot.kind {
        case .permissionRequest: return .orange
        case .exitPlan: return .purple
        case .question: return .blue
        default: return snapshot.status.isPending ? .orange : .secondary.opacity(0.8)
        }
    }
}

extension View {
    @ViewBuilder
    func feedZeroScrollContentMargins() -> some View {
        if #available(macOS 14.0, *) {
            contentMargins(.all, 0, for: .scrollContent)
        } else {
            self
        }
    }
}

struct FeedKeyboardFocusBridge: NSViewRepresentable {
    let placement: FeedPlacement
    let focusScopeID: UUID
    let focusRequest: Int
    let onHostChange: (FeedKeyboardFocusView?) -> Void
    let onEscape: () -> Void
    let onMoveSelection: (Int) -> Void
    let onActivateSelection: () -> Void
    let onFocusFirstItemRequested: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onFocusSnapshotChanged: (FeedFocusSnapshot) -> Void

    final class Coordinator {
        var onHostChange: (FeedKeyboardFocusView?) -> Void
        weak var host: FeedKeyboardFocusView?
        var lastFocusRequest: Int

        init(
            onHostChange: @escaping (FeedKeyboardFocusView?) -> Void,
            focusRequest: Int
        ) {
            self.onHostChange = onHostChange
            self.lastFocusRequest = focusRequest
        }

        func attach(_ host: FeedKeyboardFocusView) {
            guard self.host !== host else { return }
            self.host = host
            onHostChange(host)
        }

        func detach(_ host: FeedKeyboardFocusView) {
            guard self.host === host else { return }
            self.host = nil
            onHostChange(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHostChange: onHostChange, focusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> FeedKeyboardFocusView {
        let view = FeedKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.placement = placement
        view.feedFocusScopeID = focusScopeID
        view.onEscape = onEscape
        view.onMoveSelection = onMoveSelection
        view.onActivateSelection = onActivateSelection
        view.onFocusFirstItemRequested = onFocusFirstItemRequested
        view.onFocusChanged = onFocusChanged
        view.onFocusSnapshotChanged = onFocusSnapshotChanged
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: FeedKeyboardFocusView, context: Context) {
        context.coordinator.onHostChange = onHostChange
        context.coordinator.attach(nsView)
        nsView.placement = placement
        nsView.feedFocusScopeID = focusScopeID
        nsView.onEscape = onEscape
        nsView.onMoveSelection = onMoveSelection
        nsView.onActivateSelection = onActivateSelection
        nsView.onFocusFirstItemRequested = onFocusFirstItemRequested
        nsView.onFocusChanged = onFocusChanged
        nsView.onFocusSnapshotChanged = onFocusSnapshotChanged
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
        if !placement.usesRightSidebarFocusCoordinator,
           focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            _ = nsView.focusHostFromCoordinator()
        }
    }

    static func dismantleNSView(_ nsView: FeedKeyboardFocusView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }
}

final class FeedKeyboardFocusView: NSView {
    var placement: FeedPlacement = .rightSidebar
    var feedFocusScopeID = UUID()
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onFocusFirstItemRequested: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onFocusSnapshotChanged: ((FeedFocusSnapshot) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        if let window {
            dlog("feed.focus.host attach window=\(ObjectIdentifier(window)) placement=\(placement)")
        }
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard placement.usesRightSidebarFocusCoordinator, let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFeedHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog(
                "feed.focus.host escape window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
                "fr=\(feedDebugResponderSummary(window?.firstResponder))"
            )
#endif
            onEscape?()
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let chars = event.charactersIgnoringModifiers ?? ""
        dlog(
            "feed.focus.host keyDown key=\(event.keyCode) chars=\(chars) " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }

        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutModifier = !normalizedFlags.intersection([.command, .control, .option]).isEmpty
        guard !hasShortcutModifier else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onActivateSelection?()
            return
        case 53:
            onEscape?()
            return
        default:
            break
        }

        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChanged?(true)
        }
#if DEBUG
        dlog(
            "feed.focus.host become result=\(result ? 1 : 0) " +
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChanged?(false)
        }
#if DEBUG
        dlog(
            "feed.focus.host resign result=\(result ? 1 : 0) " +
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    func focusFirstItemFromCoordinator() {
        onFocusFirstItemRequested?()
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else { return false }
#if DEBUG
        let before = feedDebugResponderSummary(window.firstResponder)
#endif
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "feed.focus.host request result=\(result ? 1 : 0) " +
            "window=\(ObjectIdentifier(window)) before=\(before) " +
            "after=\(feedDebugResponderSummary(window.firstResponder))"
        )
#endif
        return result
    }

    func applyFocusSnapshotFromController(_ snapshot: FeedFocusSnapshot) {
        onFocusSnapshotChanged?(snapshot)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let feedResponder = responder as? FeedKeyboardFocusResponder else { return false }
        return feedResponder.feedFocusScopeID == feedFocusScopeID
    }
}

// MARK: - Row snapshot + actions (respects snapshot-boundary rule)

/// Immutable snapshot of a `WorkstreamItem` handed to row views so rows
/// never hold a reference to the store.
