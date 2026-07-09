#if DEBUG
public import Foundation

/// The parsed result of the goto-split active-element probe page script.
///
/// ``GotoSplitUITestRecorder`` runs a page script (``script(expectedInputIdLiteral:)``)
/// inside a `BrowserPanel`'s `WKWebView` to read back the current
/// `document.activeElement` focus state (optionally awaiting a specific input id).
/// The script source and the `[String: Any]` -> typed decode are pure data with
/// no AppKit/live-state coupling, so they live here; the recorder keeps the
/// `awaitingInputId` JavaScript-literal escaping and the capture-file write
/// app-side. The decoded fields mirror the legacy inline `evaluateJavaScript`
/// parse byte-for-byte (string fields default to `""`, the two boolean-shaped
/// fields default to `"false"`).
public struct ActiveElementProbeResult: Sendable {
    /// The page's reported `document.activeElement` id (`""` when absent).
    public let id: String
    /// The active element's lowercased tag name (`""` when absent).
    public let tag: String
    /// The active element's lowercased `type` attribute (`""` when absent).
    public let type: String
    /// Whether the active element is editable, as a string (`"true"`/`"false"`, default `"false"`).
    public let editable: String
    /// The page-side tracked focus-state id (`""` when absent).
    public let trackedFocusStateId: String
    /// Whether the page-side address-bar focus tracker was installed, as a string (`"true"`/`"false"`, default `"false"`).
    public let focusTrackerInstalled: String

    /// Decodes the raw `evaluateJavaScript` result object into typed fields,
    /// reproducing the legacy inline cast-and-default behavior exactly.
    ///
    /// - Parameter jsResult: The `Any?` value handed to the
    ///   `evaluateJavaScript` completion handler.
    public init(jsResult: Any?) {
        let payload = jsResult as? [String: Any]
        self.id = (payload?["id"] as? String) ?? ""
        self.tag = (payload?["tag"] as? String) ?? ""
        self.type = (payload?["type"] as? String) ?? ""
        self.editable = (payload?["editable"] as? String) ?? "false"
        self.trackedFocusStateId = (payload?["trackedFocusStateId"] as? String) ?? ""
        self.focusTrackerInstalled = (payload?["focusTrackerInstalled"] as? String) ?? "false"
    }

    /// The probe's six fields as the legacy `[String: String]` snapshot object,
    /// keyed exactly as the inline `evaluateJavaScript` completion built it
    /// (`id`/`tag`/`type`/`editable`/`trackedFocusStateId`/`focusTrackerInstalled`).
    public var snapshotFields: [String: String] {
        [
            "id": id,
            "tag": tag,
            "type": type,
            "editable": editable,
            "trackedFocusStateId": trackedFocusStateId,
            "focusTrackerInstalled": focusTrackerInstalled
        ]
    }

    /// The capture-file entries for one recorded active-element probe, re-keyed
    /// under `keyPrefix`, byte-identical to the legacy `recordActiveElement`
    /// `writeData` payload (panel id plus the six prefixed snapshot fields, each
    /// with the legacy default of `""` for the string fields and `"false"` for
    /// the two boolean-shaped fields).
    ///
    /// - Parameters:
    ///   - keyPrefix: The scenario key prefix (e.g. `"addressBarExit"`).
    ///   - panelId: The browser panel the probe ran in.
    public func recordedFields(keyPrefix: String, panelId: UUID) -> [String: String] {
        let snapshot = snapshotFields
        return [
            "\(keyPrefix)PanelId": panelId.uuidString,
            "\(keyPrefix)ActiveElementId": snapshot["id"] ?? "",
            "\(keyPrefix)ActiveElementTag": snapshot["tag"] ?? "",
            "\(keyPrefix)ActiveElementType": snapshot["type"] ?? "",
            "\(keyPrefix)ActiveElementEditable": snapshot["editable"] ?? "false",
            "\(keyPrefix)TrackedFocusStateId": snapshot["trackedFocusStateId"] ?? "",
            "\(keyPrefix)FocusTrackerInstalled": snapshot["focusTrackerInstalled"] ?? "false"
        ]
    }

    /// The active-element probe page script, byte-identical to the legacy inline
    /// source. `expectedInputIdLiteral` is interpolated as a JavaScript literal
    /// (a quoted string or `null`) by the caller.
    ///
    /// - Parameter expectedInputIdLiteral: The already-escaped JavaScript literal
    ///   for the awaited input id, or `"null"` when no specific id is awaited.
    public static func script(expectedInputIdLiteral: String) -> String {
        """
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
    }
}
#endif
