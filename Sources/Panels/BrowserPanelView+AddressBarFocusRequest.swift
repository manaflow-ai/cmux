import Foundation
import SwiftUI
import AppKit

extension BrowserPanelView {
    func applyPendingAddressBarFocusRequestIfNeeded() {
        guard let requestId = panel.pendingAddressBarFocusRequestId else {
            return
        }
        // A recreated workspace can briefly leave outgoing and replacement views
        // subscribed to the same model. Only the visible pane owner may consume
        // the durable request; otherwise the outgoing view can acknowledge Cmd+L
        // immediately before disappearing and strand the replacement unfocused.
        guard isVisibleInUI,
              isCurrentPaneOwner,
              panel.currentAddressBarViewPresentationOwner == addressBarFocusLeaseOwner else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=inactive_view request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard panel.panelType == .browser else {
            lastHandledAddressBarFocusRequestId = requestId
            panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=chrome_hidden request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard !isCommandPaletteVisibleForPanelWindow() else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=command_palette_visible request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        guard lastHandledAddressBarFocusRequestId != requestId else {
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply.skip",
                detail: "reason=already_handled request=\(requestId.uuidString.prefix(8))"
            )
#endif
            return
        }
        lastHandledAddressBarFocusRequestId = requestId
        let selectionIntent = panel.pendingAddressBarFocusSelectionIntent
        panel.beginSuppressWebViewFocusForAddressBar()
        panel.acquireAddressBarViewFocusLease(
            owner: addressBarFocusLeaseOwner,
            reason: "addressBarFocus.request.apply"
        )
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.apply",
            detail: "request=\(requestId.uuidString.prefix(8)) selection=\(String(describing: selectionIntent))"
        )
#endif

        if addressBarFocused {
            // Re-run explicit selection behavior only for requests that own it
            // (Cmd+L), without replacing a caret from focus restoration.
            let effects = omnibarReduce(
                state: &omnibarState,
                event: .focusReasserted(
                    shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                        selectionIntent: selectionIntent
                    )
                )
            )
            applyOmnibarEffects(effects)
            refreshInlineCompletion()
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=refresh"
            )
#endif
        } else {
            setAddressBarFocused(
                true,
                reason: "request.apply",
                focusGainedSelectionIntent: selectionIntent
            )
#if DEBUG
            logBrowserFocusState(
                event: "addressBarFocus.request.apply",
                detail: "request=\(requestId.uuidString.prefix(8)) mode=set_focused"
            )
#endif
        }

        panel.acknowledgeAddressBarFocusRequest(requestId)
#if DEBUG
        logBrowserFocusState(
            event: "addressBarFocus.request.ack",
            detail: "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }
}
