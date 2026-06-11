import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation



// MARK: - UITest hooks: goto-split web view focus and active-element instrumentation (DEBUG)
extension AppDelegate {
#if DEBUG
    func focusWebViewForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) {
        guard let browserPanel = tab.browserPanel(for: browserPanelId) else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Browser panel missing"
            ])
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
        }

        func recordFocusedState() {
            guard !resolved else { return }
            guard let panel = tab.browserPanel(for: browserPanelId) else {
                resolved = true
                cleanup()
                writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Browser panel missing"
                ])
                return
            }

            tab.focusPanel(browserPanelId)

            guard isWebViewFocused(panel),
                  let (browserPaneId, terminalPaneId) = paneIdsForGotoSplitUITest(
                    tab: tab,
                    browserPanelId: browserPanelId
                  ) else {
                return
            }

            resolved = true
            cleanup()
            self.startGotoSplitUITestRecorder(browserPanelId: browserPanelId)
            writeGotoSplitTestData([
                "browserPanelId": browserPanelId.uuidString,
                "browserPaneId": browserPaneId.description,
                "terminalPaneId": terminalPaneId.description,
                "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitLeftShortcut": ghosttyGotoSplitLeftShortcut?.displayString ?? "",
                "ghosttyGotoSplitRightShortcut": ghosttyGotoSplitRightShortcut?.displayString ?? "",
                "ghosttyGotoSplitUpShortcut": ghosttyGotoSplitUpShortcut?.displayString ?? "",
                "ghosttyGotoSplitDownShortcut": ghosttyGotoSplitDownShortcut?.displayString ?? "",
                "webViewFocused": "true"
            ])
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] == "1" {
                setupFocusedInputForGotoSplitUITest(panel: panel)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            recordFocusedState()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == browserPanelId else { return }
            recordFocusedState()
        })
        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in recordFocusedState() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            if !resolved {
                cleanup()
                self.writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Timed out waiting for WKWebView focus"
                ])
            }
        }

        recordFocusedState()
    }

    func installGotoSplitUITestFocusObserversIfNeeded() {
        guard gotoSplitUITestObservers.isEmpty else { return }

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
            self.recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarFocus")
        })

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidExitAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
            self.recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarExit")
        })

    }

    private func recordGotoSplitUITestWebViewFocus(panelId: UUID, key: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        guard key.contains("Exit") else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeGotoSplitTestData([
                    key: self.isWebViewFocused(panel) ? "true" : "false",
                    "\(key)PanelId": panelId.uuidString
                ])
            }
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with focused: Bool) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData([
                key: focused ? "true" : "false",
                "\(key)PanelId": panelId.uuidString
            ])
        }

        @MainActor
        func evaluate() {
            guard !resolved,
                  let currentTabManager = self.tabManager,
                  let currentTab = currentTabManager.selectedWorkspace,
                  let currentPanel = currentTab.browserPanel(for: panelId) else {
                return
            }
            guard self.isWebViewFocused(currentPanel) else { return }
            finish(with: true)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard notification.object as? WKWebView === panel.webView else { return }
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == panelId else { return }
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved else { return }
                let focused = (self.tabManager?.selectedWorkspace?.browserPanel(for: panelId)).map(self.isWebViewFocused) ?? false
                finish(with: focused)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func setupFocusedInputForGotoSplitUITest(panel: BrowserPanel) {
        let script = """
        (() => {
          const snapshot = () => {
            const active = document.activeElement;
            return {
              focused: false,
              id: "",
              secondaryId: "",
              secondaryCenterX: -1,
              secondaryCenterY: -1,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const seed = () => {
            const ensureInput = (id, value) => {
              const existing = document.getElementById(id);
              const input = (existing && existing.tagName && existing.tagName.toLowerCase() === "input")
                ? existing
                : (() => {
                    const created = document.createElement("input");
                    created.id = id;
                    created.type = "text";
                    created.value = value;
                    return created;
                  })();
              input.autocapitalize = "off";
              input.autocomplete = "off";
              input.spellcheck = false;
              input.style.display = "block";
              input.style.width = "100%";
              input.style.margin = "0";
              input.style.padding = "8px 10px";
              input.style.border = "1px solid #5f6368";
              input.style.borderRadius = "6px";
              input.style.boxSizing = "border-box";
              input.style.fontSize = "14px";
              input.style.fontFamily = "system-ui, -apple-system, sans-serif";
              input.style.background = "white";
              input.style.color = "black";
              return input;
            };

            let container = document.getElementById("cmux-ui-test-focus-container");
            if (!container || !container.tagName || container.tagName.toLowerCase() !== "div") {
              container = document.createElement("div");
              container.id = "cmux-ui-test-focus-container";
              document.body.appendChild(container);
            }
            container.style.position = "fixed";
            container.style.left = "24px";
            container.style.top = "24px";
            container.style.width = "min(520px, calc(100vw - 48px))";
            container.style.display = "grid";
            container.style.rowGap = "12px";
            container.style.padding = "12px";
            container.style.background = "rgba(255,255,255,0.92)";
            container.style.border = "1px solid rgba(95,99,104,0.55)";
            container.style.borderRadius = "8px";
            container.style.boxShadow = "0 2px 10px rgba(0,0,0,0.2)";
            container.style.zIndex = "2147483647";

            const input = ensureInput("cmux-ui-test-focus-input", "cmux-ui-focus-primary");
            const secondaryInput = ensureInput("cmux-ui-test-focus-input-secondary", "cmux-ui-focus-secondary");
            if (input.parentElement !== container) {
              container.appendChild(input);
            }
            if (secondaryInput.parentElement !== container) {
              container.appendChild(secondaryInput);
            }

            input.focus({ preventScroll: true });
            if (typeof input.setSelectionRange === "function") {
              const end = input.value.length;
              input.setSelectionRange(end, end);
            }

            let trackedFocusId = input.getAttribute("data-cmux-addressbar-focus-id");
            if (!trackedFocusId) {
              trackedFocusId = "cmux-ui-test-focus-input-tracked";
              input.setAttribute("data-cmux-addressbar-focus-id", trackedFocusId);
            }
            const selectionStart = typeof input.selectionStart === "number" ? input.selectionStart : null;
            const selectionEnd = typeof input.selectionEnd === "number" ? input.selectionEnd : null;
            if (
              !window.__cmuxAddressBarFocusState ||
              typeof window.__cmuxAddressBarFocusState.id !== "string" ||
              window.__cmuxAddressBarFocusState.id !== trackedFocusId
            ) {
              window.__cmuxAddressBarFocusState = { id: trackedFocusId, selectionStart, selectionEnd };
            }

            const secondaryRect = secondaryInput.getBoundingClientRect();
            const viewportWidth = Math.max(Number(window.innerWidth) || 0, 1);
            const viewportHeight = Math.max(Number(window.innerHeight) || 0, 1);
            const secondaryCenterX = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.left + (secondaryRect.width / 2)) / viewportWidth)
            );
            const secondaryCenterY = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.top + (secondaryRect.height / 2)) / viewportHeight)
            );
            const active = document.activeElement;
            return {
              focused: active === input,
              id: input.id || "",
              secondaryId: secondaryInput.id || "",
              secondaryCenterX,
              secondaryCenterY,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const ready = () =>
            window.__cmuxAddressBarFocusTrackerInstalled === true &&
            String(document.readyState || "") === "complete";

          if (ready()) {
            try {
              return seed();
            } catch (_) {
              return snapshot();
            }
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              if (!ready()) return;
              try {
                finish(seed());
              } catch (_) {
                finish(snapshot());
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 4000);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """

        panel.webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let payload = result as? [String: Any]
            let focused = (payload?["focused"] as? Bool) ?? false
            let inputId = (payload?["id"] as? String) ?? ""
            let secondaryInputId = (payload?["secondaryId"] as? String) ?? ""
            let secondaryCenterX = (payload?["secondaryCenterX"] as? NSNumber)?.doubleValue ?? -1
            let secondaryCenterY = (payload?["secondaryCenterY"] as? NSNumber)?.doubleValue ?? -1
            let activeId = (payload?["activeId"] as? String) ?? ""
            let trackerInstalled = (payload?["trackerInstalled"] as? Bool) ?? false
            let trackedStateId = (payload?["trackedStateId"] as? String) ?? ""
            let readyState = (payload?["readyState"] as? String) ?? ""
            var secondaryClickOffsetX = -1.0
            var secondaryClickOffsetY = -1.0
            if let window = panel.webView.window {
                let webFrame = panel.webView.convert(panel.webView.bounds, to: nil)
                let contentHeight = Double(window.contentView?.bounds.height ?? 0)
                if webFrame.width > 1,
                   webFrame.height > 1,
                   contentHeight > 1,
                   secondaryCenterX > 0,
                   secondaryCenterX < 1,
                   secondaryCenterY > 0,
                   secondaryCenterY < 1 {
                    let xInContent = Double(webFrame.minX) + (secondaryCenterX * Double(webFrame.width))
                    let yFromTopInWeb = secondaryCenterY * Double(webFrame.height)
                    let yInContent = Double(webFrame.maxY) - yFromTopInWeb
                    let yFromTopInContent = contentHeight - yInContent
                    let titlebarHeight = max(0, Double(window.frame.height) - contentHeight)
                    secondaryClickOffsetX = xInContent
                    secondaryClickOffsetY = titlebarHeight + yFromTopInContent
                }
            }
            if focused,
               !inputId.isEmpty,
               !secondaryInputId.isEmpty,
               inputId == activeId,
               trackerInstalled,
               !trackedStateId.isEmpty,
               secondaryCenterX > 0,
               secondaryCenterX < 1,
               secondaryCenterY > 0,
               secondaryCenterY < 1,
               secondaryClickOffsetX > 0,
               secondaryClickOffsetY > 0 {
                self.writeGotoSplitTestData([
                    "webInputFocusSeeded": "true",
                    "webInputFocusElementId": inputId,
                    "webInputFocusSecondaryElementId": secondaryInputId,
                    "webInputFocusSecondaryCenterX": "\(secondaryCenterX)",
                    "webInputFocusSecondaryCenterY": "\(secondaryCenterY)",
                    "webInputFocusSecondaryClickOffsetX": "\(secondaryClickOffsetX)",
                    "webInputFocusSecondaryClickOffsetY": "\(secondaryClickOffsetY)",
                    "webInputFocusActiveElementId": activeId,
                    "webInputFocusTrackerInstalled": trackerInstalled ? "true" : "false",
                    "webInputFocusTrackedStateId": trackedStateId,
                    "webInputFocusReadyState": readyState
                ])
                return
            }
            self.writeGotoSplitTestData([
                "webInputFocusSeeded": "false",
                "setupError": "Timed out focusing page input for omnibar restore test"
            ])
        }
    }

    private func recordGotoSplitUITestActiveElement(panelId: UUID, keyPrefix: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        let expectedInputId = keyPrefix == "addressBarExit" ? gotoSplitUITestExpectedInputId() : nil
        let capture: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.evaluateGotoSplitUITestActiveElement(
                panel: panel,
                awaitingInputId: expectedInputId
            ) { snapshot in
                self.writeGotoSplitTestData([
                    "\(keyPrefix)PanelId": panelId.uuidString,
                    "\(keyPrefix)ActiveElementId": snapshot["id"] ?? "",
                    "\(keyPrefix)ActiveElementTag": snapshot["tag"] ?? "",
                    "\(keyPrefix)ActiveElementType": snapshot["type"] ?? "",
                    "\(keyPrefix)ActiveElementEditable": snapshot["editable"] ?? "false",
                    "\(keyPrefix)TrackedFocusStateId": snapshot["trackedFocusStateId"] ?? "",
                    "\(keyPrefix)FocusTrackerInstalled": snapshot["focusTrackerInstalled"] ?? "false"
                ])
            }
        }

        if expectedInputId == nil {
            DispatchQueue.main.async {
                Task { @MainActor in capture() }
            }
        } else {
            Task { @MainActor in capture() }
        }
    }

    private func evaluateGotoSplitUITestActiveElement(
        panel: BrowserPanel,
        awaitingInputId: String? = nil,
        completion: @escaping ([String: String]) -> Void
    ) {
        let expectedInputIdLiteral = awaitingInputId?.javaScriptStringLiteral ?? "null"
        let script = """
        (() => {
          const expectedInputId = \(expectedInputIdLiteral);
          const snapshot = () => {
            try {
              const active = document.activeElement;
              if (!active) {
                return {
                  id: "",
                  tag: "",
                  type: "",
                  editable: "false",
                  trackedFocusStateId: "",
                  focusTrackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
                };
              }
              const tag = (active.tagName || "").toLowerCase();
              const type = (active.type || "").toLowerCase();
              const editable =
                !!active.isContentEditable ||
                tag === "textarea" ||
                (tag === "input" && type !== "hidden");
              return {
                id: typeof active.id === "string" ? active.id : "",
                tag,
                type,
                editable: editable ? "true" : "false",
                trackedFocusStateId:
                  window.__cmuxAddressBarFocusState &&
                  typeof window.__cmuxAddressBarFocusState.id === "string"
                    ? window.__cmuxAddressBarFocusState.id
                    : "",
                focusTrackerInstalled:
                  window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
              };
            } catch (_) {
              return {
                id: "",
                tag: "",
                type: "",
                editable: "false",
                trackedFocusStateId: "",
                focusTrackerInstalled: "false"
              };
            }
          };
          const matchesExpectation = (state) =>
            !expectedInputId || (typeof expectedInputId === "string" && state.id === expectedInputId);

          const initial = snapshot();
          if (matchesExpectation(initial)) {
            return initial;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              const state = snapshot();
              if (matchesExpectation(state)) {
                finish(state);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "focusin", true);
            addListener(document, "focusout", true);
            addListener(document, "selectionchange", true);
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 1500);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """

        panel.webView.evaluateJavaScript(script) { result, _ in
            let payload = result as? [String: Any]
            completion([
                "id": (payload?["id"] as? String) ?? "",
                "tag": (payload?["tag"] as? String) ?? "",
                "type": (payload?["type"] as? String) ?? "",
                "editable": (payload?["editable"] as? String) ?? "false",
                "trackedFocusStateId": (payload?["trackedFocusStateId"] as? String) ?? "",
                "focusTrackerInstalled": (payload?["focusTrackerInstalled"] as? String) ?? "false"
            ])
        }
    }

    private func gotoSplitUITestExpectedInputId() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return loadGotoSplitTestData(at: path)["webInputFocusElementId"]
    }

#endif
}
