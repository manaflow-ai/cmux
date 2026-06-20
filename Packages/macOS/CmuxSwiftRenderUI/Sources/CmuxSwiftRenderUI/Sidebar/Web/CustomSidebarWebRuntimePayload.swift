import CmuxSwiftRender
import Foundation
import SwiftUI

/// Builds the runtime payload injected into an HTML custom sidebar.
struct CustomSidebarWebRuntimePayload {
    let fileURL: URL
    let dataContext: [String: SwiftValue]
    let contentInsets: CustomSidebarContentInsets
    let colorScheme: ColorScheme

    var scriptSource: String? {
        guard let json = jsonString else { return nil }
        return """
        (() => {
          const payload = \(json);
          const root = window.cmux || {};
          window.cmux = root;
          root.sidebar = payload;
          root.postAction = root.postAction || ((action) => {
            window.webkit?.messageHandlers?.cmuxSidebarAction?.postMessage(action);
          });
          document.documentElement.dataset.cmuxColorScheme = payload.theme.colorScheme;
          document.documentElement.style.setProperty("--cmux-sidebar-safe-top", `${payload.contentInsets.top}px`);
          document.documentElement.style.setProperty("--cmux-sidebar-safe-bottom", `${payload.contentInsets.bottom}px`);
          document.documentElement.style.setProperty("--cmux-sidebar-foreground", payload.theme.foreground);
          document.documentElement.style.setProperty("--cmux-sidebar-secondary", payload.theme.secondary);
          document.documentElement.style.setProperty("--cmux-sidebar-accent", payload.theme.accent);
          document.documentElement.style.setProperty("--cmux-sidebar-background", payload.theme.background);
          if (!document.getElementById("cmux-sidebar-native-style")) {
            const style = document.createElement("style");
            style.id = "cmux-sidebar-native-style";
            style.textContent = `
              :root {
                color-scheme: light dark;
                font: -apple-system-body;
                background: transparent;
              }
              html, body {
                min-height: 100%;
                margin: 0;
                background: transparent;
                color: var(--cmux-sidebar-foreground);
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
                font-size: 13px;
              }
              body {
                box-sizing: border-box;
                padding: calc(8px + var(--cmux-sidebar-safe-top)) 12px calc(16px + var(--cmux-sidebar-safe-bottom));
              }
              button, input, select, textarea {
                font: inherit;
              }
              button {
                border-radius: 6px;
              }
              * {
                box-sizing: border-box;
              }
            `;
            (document.head || document.documentElement).appendChild(style);
          }
          window.dispatchEvent(new CustomEvent("cmuxsidebarupdate", { detail: payload }));
        })();
        """
    }

    private var jsonString: String? {
        let object: [String: Any] = [
            "data": CustomSidebarWebSwiftValueJSON(value: .object(dataContext)).jsonObject,
            "contentInsets": [
                "top": Double(contentInsets.top),
                "bottom": Double(contentInsets.bottom),
            ],
            "theme": [
                "colorScheme": colorScheme == .dark ? "dark" : "light",
                "foreground": colorScheme == .dark ? "rgba(255,255,255,0.92)" : "rgba(0,0,0,0.88)",
                "secondary": colorScheme == .dark ? "rgba(255,255,255,0.58)" : "rgba(0,0,0,0.55)",
                "accent": "#0A84FF",
                "background": "transparent",
            ],
            "file": [
                "name": fileURL.deletingPathExtension().lastPathComponent,
                "path": fileURL.path,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
