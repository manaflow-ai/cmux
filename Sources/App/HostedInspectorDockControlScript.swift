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
            function callOriginal(fn, event) {
                return typeof fn === "function" ? fn.call(WI, event) : null;
            }
            function installWrapper(methodName, originalName, wrapper) {
                if (typeof WI[originalName] !== "function") {
                    if (typeof WI[methodName] !== "function")
                        return false;
                    WI[originalName] = WI[methodName];
                }
                WI[methodName] = wrapper;
                return true;
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
                updateButton(WI._dockLeftTabBarButton, disallowSideDock || (!detached && dockedLeft));
                updateButton(WI._dockRightTabBarButton, disallowSideDock || (!detached && dockedRight));
                updateButtons([
                    WI._dockBottomTabBarButton,
                    WI._dockBottomNavigationItem,
                    WI._dockBottomButton,
                ], !detached && dockedBottom);
                updateButtons([
                    WI._detachTabBarButton,
                    WI._detachNavigationItem,
                    WI._undockTabBarButton,
                    WI._undockButton,
                ], detached);
            }
            WI.__cmuxAllowSideDock = allowSideDock;
            WI.__cmuxDetachedFromHostWindow = detachedFromHostWindow;
            installWrapper("_dockLeft", "__cmuxOriginalDockLeft", function(event) {
                if (!WI.__cmuxAllowSideDock)
                    return callOriginal(WI._dockBottom, event);
                return callOriginal(WI.__cmuxOriginalDockLeft, event);
            });
            installWrapper("_dockRight", "__cmuxOriginalDockRight", function(event) {
                if (!WI.__cmuxAllowSideDock)
                    return callOriginal(WI._dockBottom, event);
                return callOriginal(WI.__cmuxOriginalDockRight, event);
            });
            installWrapper("_togglePreviousDockConfiguration", "__cmuxOriginalTogglePreviousDockConfiguration", function(event) {
                const dockConfiguration = WI.DockConfiguration || {};
                const previousSideDock = WI._previousDockConfiguration === dockConfiguration.Left ||
                    WI._previousDockConfiguration === dockConfiguration.Right;
                if (!WI.__cmuxAllowSideDock && previousSideDock)
                    return callOriginal(WI._dockBottom, event);
                return callOriginal(WI.__cmuxOriginalTogglePreviousDockConfiguration, event);
            });
            installWrapper("_updateDockNavigationItems", "__cmuxOriginalUpdateDockNavigationItems", function(...args) {
                if (typeof WI.__cmuxOriginalUpdateDockNavigationItems === "function")
                    WI.__cmuxOriginalUpdateDockNavigationItems.apply(WI, args);
                enforceDockControls();
            });
            if (typeof WI._updateDockNavigationItems === "function")
                WI._updateDockNavigationItems();
            else
                enforceDockControls();
            return WI.__cmuxAllowSideDock;
        })();
        """
    }
}
