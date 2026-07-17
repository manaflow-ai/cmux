import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

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

    typealias Coordinator = FeedKeyboardFocusBridgeCoordinator

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
