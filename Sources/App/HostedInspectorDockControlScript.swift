struct HostedInspectorDockControlScript {
    let allowSideDock: Bool
    let detachedFromHostWindow: Bool

    var source: String {
        let allowSideDockLiteral = allowSideDock ? "true" : "false"
        let detachedFromHostWindowLiteral = detachedFromHostWindow ? "true" : "false"
        return """
        (() => {
            if (typeof WI === "undefined")
                return null;
            const allowSideDock = \(allowSideDockLiteral);
            const detachedFromHostWindow = \(detachedFromHostWindowLiteral);
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
            function updateButtons(buttons, hidden) {
                for (const button of buttons)
                    updateButton(button, hidden);
            }
            function postDockRequest(side) {
                const handler = window.webkit &&
                    window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.cmuxDevToolsDock;
                if (!handler || typeof handler.postMessage !== "function")
                    return false;
                handler.postMessage({ side, detachedFromHostWindow: WI.__cmuxDetachedFromHostWindow });
                return true;
            }
            function interceptDockButton(button, side) {
                if (!button || !button.element)
                    return;
                const installedKey = "__cmuxDockRequest_" + side;
                if (button.element[installedKey])
                    return;
                button.element[installedKey] = true;
                button.element.addEventListener("click", (event) => {
                    if (!WI.__cmuxDetachedFromHostWindow)
                        return;
                    if (!postDockRequest(side))
                        return;
                    event.preventDefault();
                    event.stopImmediatePropagation();
                }, true);
            }
            function interceptDockButtons(buttons, side) {
                for (const button of buttons)
                    interceptDockButton(button, side);
            }
            function dockMatches(enumValue, literal) {
                const configuration = WI.dockConfiguration;
                if (configuration === enumValue)
                    return true;
                return String(configuration).toLowerCase() === literal;
            }
            function enforceDockControls() {
                const disallowSideDock = !WI.__cmuxAllowSideDock;
                const dockConfiguration = WI.DockConfiguration || {};
                const dockedLeft = dockMatches(dockConfiguration.Left, "left");
                const dockedRight = dockMatches(dockConfiguration.Right, "right");
                const dockedBottom = !WI.__cmuxDetachedFromHostWindow &&
                    dockMatches(dockConfiguration.Bottom, "bottom");
                const detached = WI.__cmuxDetachedFromHostWindow ||
                    dockMatches(dockConfiguration.Detached, "detached") ||
                    dockMatches(dockConfiguration.Undocked, "undocked");
                updateButton(WI._dockLeftTabBarButton, disallowSideDock || dockedLeft);
                updateButton(WI._dockRightTabBarButton, disallowSideDock || dockedRight);
                updateButtons([
                    WI._dockBottomTabBarButton,
                    WI._dockBottomNavigationItem,
                    WI._dockBottomButton,
                ], dockedBottom);
                updateButtons([
                    WI._detachTabBarButton,
                    WI._detachNavigationItem,
                    WI._undockTabBarButton,
                    WI._undockButton,
                ], detached);
                interceptDockButton(WI._dockLeftTabBarButton, "left");
                interceptDockButton(WI._dockRightTabBarButton, "right");
                interceptDockButtons([
                    WI._dockBottomTabBarButton,
                    WI._dockBottomNavigationItem,
                    WI._dockBottomButton,
                ], "bottom");
            }
            WI.__cmuxAllowSideDock = allowSideDock;
            WI.__cmuxDetachedFromHostWindow = detachedFromHostWindow;
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
                const dockConfiguration = WI.DockConfiguration || {};
                const previousSideDock = WI._previousDockConfiguration === dockConfiguration.Left ||
                    WI._previousDockConfiguration === dockConfiguration.Right;
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
        """
    }
}
