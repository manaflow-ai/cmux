import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Hosted Inspector Dock Management
extension WebViewRepresentable.HostContainerView {
        func recordPreferredHostedInspectorWidth(_ width: CGFloat, containerBounds: NSRect) {
            preferredHostedInspectorWidth = width
            guard containerBounds.width > 0 else {
                preferredHostedInspectorWidthFraction = nil
                onPreferredHostedInspectorWidthChanged?(width, nil)
                return
            }
            preferredHostedInspectorWidthFraction = width / containerBounds.width
            onPreferredHostedInspectorWidthChanged?(width, preferredHostedInspectorWidthFraction)
        }

        func resolvedPreferredHostedInspectorWidth(in containerBounds: NSRect) -> CGFloat? {
            if let preferredHostedInspectorWidthFraction, containerBounds.width > 0 {
                return max(0, containerBounds.width * preferredHostedInspectorWidthFraction)
            }
            return preferredHostedInspectorWidth
        }

        func setPreferredHostedInspectorWidth(width: CGFloat?, widthFraction: CGFloat?) {
            preferredHostedInspectorWidth = width
            preferredHostedInspectorWidthFraction = widthFraction
        }

        func recordHostedInspectorSideDockWidth(_ width: CGFloat) {
            guard width > 1 else { return }
            recordedHostedInspectorSideDockWidth = max(Self.minimumHostedInspectorWidth, width)
        }

        private func shouldAllowHostedInspectorManualSideDock() -> Bool {
            let containerWidth = max(0, bounds.width)
            guard containerWidth > 1 else { return true }
            let baselineWidth = max(
                Self.minimumHostedInspectorWidth,
                recordedHostedInspectorSideDockWidth ?? Self.minimumHostedInspectorWidth
            )
            return containerWidth - baselineWidth >= Self.minimumHostedInspectorPageWidthForSideDock
        }

        func updateHostedInspectorDockControlAvailabilityIfNeeded(reason: String) {
            guard let hostedInspectorFrontendWebView else {
                lastHostedInspectorManualSideDockAllowed = nil
                return
            }

            let sideDockAllowed = shouldAllowHostedInspectorManualSideDock()
            guard lastHostedInspectorManualSideDockAllowed != sideDockAllowed else { return }
            lastHostedInspectorManualSideDockAllowed = sideDockAllowed

            let sideDockAllowedLiteral = sideDockAllowed ? "true" : "false"
#if DEBUG
            let recordedWidthDesc = recordedHostedInspectorSideDockWidth.map {
                String(format: "%.1f", $0)
            } ?? "nil"
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).dockControls " +
                "host=\(Self.debugObjectID(self)) allowSideDock=\(sideDockAllowed ? 1 : 0) " +
                "recordedWidth=\(recordedWidthDesc) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                """
                (() => {
                    if (typeof WI === "undefined")
                        return null;
                    const allowSideDock = \(sideDockAllowedLiteral);
                    if (!WI.__cmuxOriginalUpdateDockNavigationItems && typeof WI._updateDockNavigationItems === "function")
                        WI.__cmuxOriginalUpdateDockNavigationItems = WI._updateDockNavigationItems;
                    if (!WI.__cmuxOriginalDockLeft && typeof WI._dockLeft === "function")
                        WI.__cmuxOriginalDockLeft = WI._dockLeft;
                    if (!WI.__cmuxOriginalDockRight && typeof WI._dockRight === "function")
                        WI.__cmuxOriginalDockRight = WI._dockRight;
                    if (!WI.__cmuxOriginalTogglePreviousDockConfiguration && typeof WI._togglePreviousDockConfiguration === "function")
                        WI.__cmuxOriginalTogglePreviousDockConfiguration = WI._togglePreviousDockConfiguration;
                    function callOriginal(fn, event) {
                        return typeof fn === "function" ? fn.call(WI, event) : null;
                    }
                    function updateButton(button, hidden) {
                        if (!button)
                            return;
                        button.hidden = hidden;
                        if (button.element) {
                            button.element.style.display = hidden ? "none" : "";
                            button.element.style.pointerEvents = hidden ? "none" : "";
                        }
                    }
                    function enforceDockControls() {
                        const disallowSideDock = !WI.__cmuxAllowSideDock;
                        updateButton(WI._dockLeftTabBarButton, disallowSideDock || WI.dockConfiguration === WI.DockConfiguration.Left);
                        updateButton(WI._dockRightTabBarButton, disallowSideDock || WI.dockConfiguration === WI.DockConfiguration.Right);
                    }
                    WI.__cmuxAllowSideDock = allowSideDock;
                    WI._dockLeft = function(event) {
                        if (!WI.__cmuxAllowSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__cmuxOriginalDockLeft, event);
                    };
                    WI._dockRight = function(event) {
                        if (!WI.__cmuxAllowSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__cmuxOriginalDockRight, event);
                    };
                    WI._togglePreviousDockConfiguration = function(event) {
                        const previousSideDock = WI._previousDockConfiguration === WI.DockConfiguration.Left || WI._previousDockConfiguration === WI.DockConfiguration.Right;
                        if (!WI.__cmuxAllowSideDock && previousSideDock)
                            return callOriginal(WI._dockBottom, event);
                        return callOriginal(WI.__cmuxOriginalTogglePreviousDockConfiguration, event);
                    };
                    WI._updateDockNavigationItems = function(...args) {
                        if (typeof WI.__cmuxOriginalUpdateDockNavigationItems === "function")
                            WI.__cmuxOriginalUpdateDockNavigationItems.apply(WI, args);
                        enforceDockControls();
                    };
                    WI._updateDockNavigationItems();
                    return WI.__cmuxAllowSideDock;
                })();
                """,
                completionHandler: nil
            )
        }

        private func ensureHostedInspectorSideDockContainerView() -> HostedInspectorSideDockContainerView {
            if let hostedInspectorSideDockContainerView,
               hostedInspectorSideDockContainerView.superview === self {
                hostedInspectorSideDockContainerView.isHidden = false
                return hostedInspectorSideDockContainerView
            }

            let containerView = HostedInspectorSideDockContainerView(frame: bounds)
            containerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(containerView, positioned: .above, relativeTo: localInlineSlotView)
            hostedInspectorSideDockConstraints = [
                containerView.topAnchor.constraint(equalTo: topAnchor),
                containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            NSLayoutConstraint.activate(hostedInspectorSideDockConstraints)
            hostedInspectorSideDockContainerView = containerView
            return containerView
        }

        private func moveHostedInspectorSubviewIfNeeded(_ view: NSView, to container: NSView) {
            guard view.superview !== container else { return }
            let frameInWindow = view.superview?.convert(view.frame, to: nil) ?? convert(view.frame, to: nil)
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: nil)
            view.frame = container.convert(frameInWindow, from: nil)
        }

        func isHostedInspectorSideDockActive() -> Bool {
            guard let hostedInspectorSideDockContainerView,
                  let hostedInspectorSideDockPageView,
                  let hostedInspectorSideDockInspectorView else {
                return false
            }
            return hostedInspectorSideDockPageView.superview === hostedInspectorSideDockContainerView &&
                hostedInspectorSideDockInspectorView.superview === hostedInspectorSideDockContainerView
        }

        private func isHostedInspectorSideDockHit(_ hit: HostedInspectorDividerHit) -> Bool {
            guard let hostedInspectorSideDockContainerView else { return false }
            return hit.containerView === hostedInspectorSideDockContainerView
        }

        private func activateHostedInspectorSideDockIfNeeded(using hit: HostedInspectorDividerHit) {
            let containerView = ensureHostedInspectorSideDockContainerView()
            moveHostedInspectorSubviewIfNeeded(hit.pageView, to: containerView)
            moveHostedInspectorSubviewIfNeeded(hit.inspectorView, to: containerView)
            hostedInspectorSideDockPageView = hit.pageView
            hostedInspectorSideDockInspectorView = hit.inspectorView
            hostedInspectorSideDockDockSide = hit.dockSide
            layoutHostedInspectorSideDockIfNeeded(reason: "sideDock.activate")
        }

        @discardableResult
        func promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded() -> Bool {
            guard !isHostedInspectorSideDockActive(),
                  let slotView = localInlineSlotView,
                  let hit = hostedInspectorDividerCandidateUsingKnownWebViews(in: slotView) else {
                return false
            }

            // The inspector frontend sometimes reports its dock configuration a tick
            // late after local-inline reattach. Promote the visible left/right split
            // immediately so drag routing stays symmetric on both dock sides.
            activateHostedInspectorSideDockIfNeeded(using: hit)
            return isHostedInspectorSideDockActive()
        }

        func deactivateHostedInspectorSideDockIfNeeded(reparentTo slotView: WindowBrowserSlotView?) {
            guard let slotView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView else {
                hostedInspectorSideDockPageView = nil
                hostedInspectorSideDockInspectorView = nil
                hostedInspectorSideDockDockSide = nil
                hostedInspectorSideDockContainerView?.isHidden = true
                return
            }

            moveHostedInspectorSubviewIfNeeded(pageView, to: slotView)
            moveHostedInspectorSubviewIfNeeded(inspectorView, to: slotView)
            hostedInspectorSideDockPageView = nil
            hostedInspectorSideDockInspectorView = nil
            hostedInspectorSideDockDockSide = nil
            hostedInspectorSideDockContainerView?.isHidden = true
        }

        func layoutHostedInspectorSideDockIfNeeded(reason: String) {
            guard let containerView = hostedInspectorSideDockContainerView,
                  let pageView = hostedInspectorSideDockPageView,
                  let inspectorView = hostedInspectorSideDockInspectorView,
                  let dockSide = hostedInspectorSideDockDockSide else {
                return
            }
            let preferredWidth = resolvedPreferredHostedInspectorWidth(in: containerView.bounds) ?? max(0, inspectorView.frame.width)
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                ),
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        func normalizeHostedInspectorLayoutIfNeeded(reason: String) {
            if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).adaptive") {
                return
            }
            _ = promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
            if isHostedInspectorSideDockActive() {
                layoutHostedInspectorSideDockIfNeeded(reason: reason)
            } else if !hasStoredHostedInspectorWidthPreference {
                captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
            }
        }

        private func shouldForceHostedInspectorBottomDock(using hit: HostedInspectorDividerHit) -> Bool {
            let containerWidth = max(0, hit.containerView.bounds.width)
            guard containerWidth > 1 else { return false }

            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            let currentPageWidth = max(0, hit.pageView.frame.width)
            let remainingPageWidth = max(0, containerWidth - max(Self.minimumHostedInspectorWidth, currentInspectorWidth))
            let effectivePageWidth = min(currentPageWidth, remainingPageWidth)

            return effectivePageWidth < Self.minimumHostedInspectorPageWidthForSideDock
        }

        @discardableResult
        private func requestAdaptiveHostedInspectorBottomDock(reason: String) -> Bool {
            let now = Date()
            if let adaptiveBottomDockRequestCooldownDeadline, adaptiveBottomDockRequestCooldownDeadline > now {
                return true
            }
            guard let hostedInspectorFrontendWebView else { return false }

            adaptiveBottomDockRequestCooldownDeadline = now.addingTimeInterval(Self.adaptiveBottomDockRequestCooldown)
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: reason)
#if DEBUG
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).adaptiveBottomDock " +
                "host=\(Self.debugObjectID(self)) bounds=\(Self.debugRect(bounds))"
            )
#endif
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI !== 'undefined' ? WI._dockBottom() : null"
            ) { [weak self] _, _ in
                self?.scheduleHostedInspectorDockConfigurationSync(
                    reason: "\(reason).adaptiveBottomDock"
                )
            }
            return true
        }

        @discardableResult
        func enforceAdaptiveBottomDockIfNeeded(reason: String) -> Bool {
            guard let hit = hostedInspectorDividerCandidate(),
                  shouldForceHostedInspectorBottomDock(using: hit) else {
                return false
            }
            recordHostedInspectorSideDockWidth(hit.inspectorView.frame.width)
            return requestAdaptiveHostedInspectorBottomDock(reason: reason)
        }

        func scheduleHostedInspectorDockConfigurationSync(reason: String) {
            hostedInspectorDockConfigurationSyncWorkItem?.cancel()
            guard hostedInspectorFrontendWebView != nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.syncHostedInspectorDockConfiguration(reason: reason)
            }
            hostedInspectorDockConfigurationSyncWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func syncHostedInspectorDockConfiguration(reason: String) {
            hostedInspectorDockConfigurationSyncWorkItem = nil
            guard let hostedInspectorFrontendWebView else { return }
            hostedInspectorFrontendWebView.evaluateJavaScript(
                "typeof WI === 'undefined' ? null : WI.dockConfiguration"
            ) { [weak self] result, _ in
                self?.applyHostedInspectorDockConfiguration(result as? String, reason: reason)
            }
        }

        private func applyHostedInspectorDockConfiguration(_ dockConfiguration: String?, reason: String) {
            switch dockConfiguration {
            case "left":
                hostedInspectorSideDockDockSide = .leading
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockLeft") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockLeft")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .leading {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockLeft")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            case "right":
                hostedInspectorSideDockDockSide = .trailing
                if isHostedInspectorSideDockActive() {
                    if enforceAdaptiveBottomDockIfNeeded(reason: "\(reason).dockRight") {
                        return
                    }
                    layoutHostedInspectorSideDockIfNeeded(reason: "\(reason).dockRight")
                } else if let slotView = localInlineSlotView,
                          let hit = hostedInspectorDividerCandidate(in: slotView),
                          hit.dockSide == .trailing {
                    if shouldForceHostedInspectorBottomDock(using: hit) {
                        _ = requestAdaptiveHostedInspectorBottomDock(reason: "\(reason).dockRight")
                        return
                    }
                    activateHostedInspectorSideDockIfNeeded(using: hit)
                }
            default:
                adaptiveBottomDockRequestCooldownDeadline = nil
                if isHostedInspectorSideDockActive() {
                    deactivateHostedInspectorSideDockIfNeeded(reparentTo: localInlineSlotView)
                    if dockConfiguration == "bottom" {
                        hostedInspectorFrontendWebView?.evaluateJavaScript(
                            "typeof WI !== 'undefined' ? WI._dockBottom() : null",
                            completionHandler: nil
                        )
                    }
                }
            }
            updateHostedInspectorDockControlAvailabilityIfNeeded(reason: "\(reason).dockConfiguration")
        }

}
