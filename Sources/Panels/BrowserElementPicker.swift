import AppKit
import Foundation
import WebKit

extension Notification.Name {
    static let browserElementPicked = Notification.Name("cmux.browserElementPicked")
}

enum BrowserElementPickNotificationKey {
    static let pick = "pick"
}

nonisolated struct BrowserElementPickRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var socketPayload: [String: Any] {
        [
            "x": x,
            "y": y,
            "width": width,
            "height": height,
        ]
    }
}

nonisolated struct BrowserElementPick: Equatable, Sendable {
    let sequence: UInt64
    let surfaceId: UUID
    let workspaceId: UUID
    let selector: String
    let selectorKind: String
    let xpath: String?
    let text: String
    let tagName: String
    let role: String?
    let label: String?
    let attributes: [String: String]
    let shadowPath: [String]
    let url: String?
    let title: String?
    let frameURL: String?
    let rect: BrowserElementPickRect?
    let timestampMs: Int64

    func withSequence(_ nextSequence: UInt64) -> BrowserElementPick {
        BrowserElementPick(
            sequence: nextSequence,
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            selector: selector,
            selectorKind: selectorKind,
            xpath: xpath,
            text: text,
            tagName: tagName,
            role: role,
            label: label,
            attributes: attributes,
            shadowPath: shadowPath,
            url: url,
            title: title,
            frameURL: frameURL,
            rect: rect,
            timestampMs: timestampMs
        )
    }

    var socketPayload: [String: Any] {
        var payload: [String: Any] = [
            "sequence": NSNumber(value: sequence),
            "surface_id": surfaceId.uuidString,
            "workspace_id": workspaceId.uuidString,
            "selector": selector,
            "selector_kind": selectorKind,
            "text": text,
            "tag": tagName,
            "timestamp_ms": NSNumber(value: timestampMs),
        ]
        if let xpath {
            payload["xpath"] = xpath
        }
        if let role {
            payload["role"] = role
        }
        if let label {
            payload["label"] = label
        }
        if !attributes.isEmpty {
            payload["attributes"] = attributes
        }
        if !shadowPath.isEmpty {
            payload["shadow_path"] = shadowPath
        }
        if let url {
            payload["url"] = url
        }
        if let title {
            payload["title"] = title
        }
        if let frameURL {
            payload["frame_url"] = frameURL
        }
        if let rect {
            payload["rect"] = rect.socketPayload
        }
        return payload
    }

    var terminalContext: String {
        let terminalPayload = BrowserElementPickSanitizer.compactPayloadForTerminal(socketPayload)
        return "# cmux browser picked element: \(BrowserElementPickSanitizer.singleLineJSONString(terminalPayload))"
    }

    static func make(
        body: [String: Any],
        surfaceId: UUID,
        workspaceId: UUID,
        pageURL: URL?,
        pageTitle: String
    ) -> BrowserElementPick? {
        let selector = BrowserElementPickSanitizer.selector(
            BrowserElementPickSanitizer.string(body["selector"])
        )
        guard !selector.isEmpty else { return nil }

        let selectorKindRaw = BrowserElementPickSanitizer.identifier(
            BrowserElementPickSanitizer.string(body["selector_kind"]),
            maxLength: 24
        )
        let selectorKind = selectorKindRaw == "shadow" ? "shadow" : "css"
        let xpath = BrowserElementPickSanitizer.optionalSelector(
            BrowserElementPickSanitizer.string(body["xpath"])
        )
        let text = BrowserElementPickSanitizer.text(
            BrowserElementPickSanitizer.string(body["text"])
        )
        let tagName = BrowserElementPickSanitizer.identifier(
            BrowserElementPickSanitizer.string(body["tag"]) ?? BrowserElementPickSanitizer.string(body["tag_name"]),
            maxLength: 48
        )
        let fallbackTag = tagName.isEmpty ? "element" : tagName
        let role = BrowserElementPickSanitizer.optionalText(
            BrowserElementPickSanitizer.string(body["role"]),
            maxLength: 80
        )
        let label = BrowserElementPickSanitizer.optionalText(
            BrowserElementPickSanitizer.string(body["label"]),
            maxLength: 200
        )
        let attributes = BrowserElementPickSanitizer.attributes(body["attributes"])
        let shadowPath = BrowserElementPickSanitizer.stringArray(body["shadow_path"], maxItems: 12, maxLength: 400)
        let url = BrowserElementPickSanitizer.optionalURLString(
            BrowserElementPickSanitizer.string(body["url"]) ?? pageURL?.absoluteString
        )
        let frameURL = BrowserElementPickSanitizer.optionalURLString(
            BrowserElementPickSanitizer.string(body["frame_url"])
        )
        let title = BrowserElementPickSanitizer.optionalText(
            BrowserElementPickSanitizer.string(body["title"]) ?? pageTitle,
            maxLength: 200
        )
        let timestampMs = BrowserElementPickSanitizer.int64(body["timestamp_ms"])
            ?? Int64(Date().timeIntervalSince1970 * 1000.0)

        return BrowserElementPick(
            sequence: 0,
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            selector: selector,
            selectorKind: selectorKind,
            xpath: xpath,
            text: text,
            tagName: fallbackTag,
            role: role,
            label: label,
            attributes: attributes,
            shadowPath: shadowPath,
            url: url,
            title: title,
            frameURL: frameURL,
            rect: BrowserElementPickSanitizer.rect(body["rect"]),
            timestampMs: timestampMs
        )
    }
}

nonisolated enum BrowserElementPickSanitizer {
    private static let dangerousScalars: Set<UInt32> = [
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0xFEFF,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    static func string(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func text(_ raw: String?, maxLength: Int = 500) -> String {
        filtered(raw, maxLength: maxLength).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func optionalText(_ raw: String?, maxLength: Int) -> String? {
        let value = text(raw, maxLength: maxLength)
        return value.isEmpty ? nil : value
    }

    static func selector(_ raw: String?, maxLength: Int = 2_000) -> String {
        filtered(raw, maxLength: maxLength).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func optionalSelector(_ raw: String?, maxLength: Int = 2_000) -> String? {
        let value = selector(raw, maxLength: maxLength)
        return value.isEmpty ? nil : value
    }

    static func identifier(_ raw: String?, maxLength: Int) -> String {
        let value = filtered(raw, maxLength: maxLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scalars = value.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func optionalURLString(_ raw: String?) -> String? {
        let value = filtered(raw, maxLength: 2_000).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func attributes(_ raw: Any?) -> [String: String] {
        guard let dictionary = raw as? [String: Any] else { return [:] }
        let allowedKeys: Set<String> = [
            "id",
            "class",
            "name",
            "type",
            "href",
            "role",
            "aria-label",
            "title",
            "alt",
            "data-testid",
            "data-test",
            "data-cy",
        ]
        var result: [String: String] = [:]
        for (rawKey, rawValue) in dictionary {
            let key = filtered(rawKey, maxLength: 80).trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedKeys.contains(key), let stringValue = string(rawValue) else { continue }
            let value = text(stringValue, maxLength: 300)
            guard !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    static func stringArray(_ raw: Any?, maxItems: Int, maxLength: Int) -> [String] {
        guard let values = raw as? [Any] else { return [] }
        return values.prefix(maxItems).compactMap { value in
            let text = selector(string(value), maxLength: maxLength)
            return text.isEmpty ? nil : text
        }
    }

    static func rect(_ raw: Any?) -> BrowserElementPickRect? {
        guard let dictionary = raw as? [String: Any],
              let x = double(dictionary["x"]),
              let y = double(dictionary["y"]),
              let width = double(dictionary["width"]),
              let height = double(dictionary["height"]),
              x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite else {
            return nil
        }
        return BrowserElementPickRect(x: x, y: y, width: max(0, width), height: max(0, height))
    }

    static func int64(_ raw: Any?) -> Int64? {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String { return Int64(value) }
        return nil
    }

    static func singleLineJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return filtered(text, maxLength: 4_000)
    }

    static func compactPayloadForTerminal(_ payload: [String: Any]) -> [String: Any] {
        let keys = [
            "selector",
            "selector_kind",
            "text",
            "tag",
            "role",
            "label",
            "url",
            "frame_url",
        ]
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = payload[key] else { continue }
            if let string = value as? String, string.isEmpty {
                continue
            }
            result[key] = value
        }
        if let attributes = payload["attributes"] {
            result["attributes"] = attributes
        }
        if let shadowPath = payload["shadow_path"] {
            result["shadow_path"] = shadowPath
        }
        return result
    }

    private static func double(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Float { return Double(value) }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private static func filtered(_ raw: String?, maxLength: Int) -> String {
        guard let raw else { return "" }
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(min(raw.unicodeScalars.count, maxLength))
        for scalar in raw.unicodeScalars {
            guard scalars.count < maxLength else { break }
            let value = scalar.value
            guard value >= 0x20,
                  !(value >= 0x7F && value <= 0x9F),
                  !dangerousScalars.contains(value) else {
                continue
            }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

nonisolated final class BrowserElementPickStore: @unchecked Sendable {
    static let shared = BrowserElementPickStore()

    private let condition = NSCondition()
    private var nextSequence: UInt64 = 0
    private var picksBySurface: [UUID: BrowserElementPick] = [:]

    func record(_ pick: BrowserElementPick) -> BrowserElementPick {
        condition.lock()
        nextSequence &+= 1
        let stored = pick.withSequence(nextSequence)
        picksBySurface[pick.surfaceId] = stored
        condition.broadcast()
        condition.unlock()
        return stored
    }

    func get(surfaceId: UUID) -> BrowserElementPick? {
        condition.lock()
        let pick = picksBySurface[surfaceId]
        condition.unlock()
        return pick
    }

    @discardableResult
    func clear(surfaceId: UUID) -> Bool {
        condition.lock()
        let removed = picksBySurface.removeValue(forKey: surfaceId) != nil
        condition.broadcast()
        condition.unlock()
        return removed
    }

    func clear(surfaceIds: [UUID]) {
        condition.lock()
        for surfaceId in surfaceIds {
            picksBySurface.removeValue(forKey: surfaceId)
        }
        condition.broadcast()
        condition.unlock()
    }

    func waitForPick(surfaceId: UUID, includeCurrent: Bool, timeoutMs: Int) -> BrowserElementPick? {
        let clampedTimeoutMs = max(0, min(timeoutMs, 120_000))
        let deadline = Date().addingTimeInterval(Double(clampedTimeoutMs) / 1000.0)
        condition.lock()
        let floor = includeCurrent ? 0 : (picksBySurface[surfaceId]?.sequence ?? nextSequence)
        defer { condition.unlock() }

        while true {
            if let pick = picksBySurface[surfaceId], pick.sequence > floor {
                return pick
            }
            guard clampedTimeoutMs > 0 else { return nil }
            if Date() >= deadline {
                return nil
            }
            condition.wait(until: deadline)
        }
    }
}

enum BrowserElementPickerBridge {
    static let messageHandlerName = "cmuxElementPicker"

    static func setActiveScript(_ isActive: Bool) -> String {
        let value = isActive ? "true" : "false"
        return """
        (() => {
          window.__cmuxElementPickerPendingActive = \(value);
          const picker = window.__cmuxElementPicker;
          if (picker && typeof picker.setActive === 'function') {
            return picker.setActive(\(value));
          }
          return false;
        })()
        """
    }

    static let scriptSource = """
    (() => {
      if (window.__cmuxElementPickerInstalled) {
        return true;
      }

      const handlerName = '\(messageHandlerName)';
      const getHandler = () => {
        try {
          return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handlerName];
        } catch (_) {
          return null;
        }
      };

      const state = window.__cmuxElementPickerState || { active: false, overlay: null };
      Object.defineProperty(window, '__cmuxElementPickerState', {
        value: state,
        writable: false,
        configurable: false,
        enumerable: false
      });
      Object.defineProperty(window, '__cmuxElementPickerInstalled', {
        value: true,
        writable: false,
        configurable: false,
        enumerable: false
      });

      const cssEscape = (value) => {
        const string = String(value || '');
        if (window.CSS && typeof window.CSS.escape === 'function') {
          return window.CSS.escape(string);
        }
        return string.replace(/[^a-zA-Z0-9_-]/g, (ch) => '\\\\' + ch);
      };

      const attributeSelectorValue = (value) => String(value || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"');

      const sanitizedText = (value, limit) => {
        return String(value || '')
          .replace(/[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]/g, '')
          .slice(0, limit)
          .trim();
      };

      const elementFromEvent = (event) => {
        const path = event && typeof event.composedPath === 'function' ? event.composedPath() : [];
        for (const item of path) {
          if (item && item.nodeType === Node.ELEMENT_NODE) return item;
        }
        return event && event.target && event.target.nodeType === Node.ELEMENT_NODE ? event.target : null;
      };

      const ensureOverlay = () => {
        if (state.overlay && state.overlay.isConnected) return state.overlay;
        const overlay = document.createElement('div');
        overlay.setAttribute('aria-hidden', 'true');
        overlay.setAttribute('role', 'presentation');
        overlay.style.cssText = [
          'position:fixed',
          'pointer-events:none',
          'z-index:2147483647',
          'border:2px solid #0a84ff',
          'background:rgba(10,132,255,0.14)',
          'display:none',
          'border-radius:3px',
          'box-sizing:border-box'
        ].join(';');
        if (!window.matchMedia || !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
          overlay.style.transition = 'top 40ms linear,left 40ms linear,width 40ms linear,height 40ms linear';
        }
        (document.body || document.documentElement).appendChild(overlay);
        state.overlay = overlay;
        return overlay;
      };

      const hideOverlay = () => {
        if (state.overlay) state.overlay.style.display = 'none';
      };

      const showOverlay = (element, picked) => {
        if (!element || typeof element.getBoundingClientRect !== 'function') {
          hideOverlay();
          return;
        }
        const rect = element.getBoundingClientRect();
        const overlay = ensureOverlay();
        overlay.style.display = 'block';
        overlay.style.borderColor = picked ? '#30d158' : '#0a84ff';
        overlay.style.background = picked ? 'rgba(48,209,88,0.16)' : 'rgba(10,132,255,0.14)';
        overlay.style.top = rect.top + 'px';
        overlay.style.left = rect.left + 'px';
        overlay.style.width = Math.max(0, rect.width) + 'px';
        overlay.style.height = Math.max(0, rect.height) + 'px';
      };

      const nthOfType = (element) => {
        let index = 1;
        let sibling = element.previousElementSibling;
        while (sibling) {
          if (sibling.localName === element.localName) index += 1;
          sibling = sibling.previousElementSibling;
        }
        return index;
      };

      const simpleSelector = (element, root) => {
        const tag = (element.localName || 'element').toLowerCase();
        if (element.id) {
          return tag + '#' + cssEscape(element.id);
        }

        for (const attributeName of ['data-testid', 'data-test', 'data-cy']) {
          const testId = element.getAttribute(attributeName);
          if (testId) {
            return tag + '[' + attributeName + '="' + attributeSelectorValue(testId) + '"]';
          }
        }

        const name = element.getAttribute('name');
        if (name) {
          return tag + '[name="' + attributeSelectorValue(name) + '"]';
        }

        const parent = element.parentElement || (root && root.host) || null;
        if (!parent) return tag;
        const sameTagSiblings = Array.prototype.filter.call(parent.children || [], (child) => child.localName === element.localName);
        return sameTagSiblings.length > 1 ? tag + ':nth-of-type(' + nthOfType(element) + ')' : tag;
      };

      const selectorPath = (element, root) => {
        const parts = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE && current !== root) {
          parts.unshift(simpleSelector(current, root));
          if (current.id) break;
          current = current.parentElement;
        }
        return parts.join(' > ');
      };

      const xpathForElement = (element) => {
        const parts = [];
        let current = element;
        while (current && current.nodeType === Node.ELEMENT_NODE) {
          const tag = (current.localName || 'element').toLowerCase();
          if (current === document.documentElement) {
            parts.unshift('html');
            break;
          }
          const index = nthOfType(current);
          const parent = current.parentElement;
          const sameTagCount = parent ? Array.prototype.filter.call(parent.children || [], (child) => child.localName === current.localName).length : 1;
          parts.unshift(sameTagCount > 1 ? tag + '[' + index + ']' : tag);
          current = parent;
        }
        return '/' + parts.join('/');
      };

      const selectorDescription = (element) => {
        const shadowPath = [];
        let current = element;
        let root = current.getRootNode ? current.getRootNode() : document;
        while (root && root.toString && String(root) === '[object ShadowRoot]') {
          shadowPath.unshift(selectorPath(current, root));
          current = root.host;
          root = current && current.getRootNode ? current.getRootNode() : document;
        }
        const outer = selectorPath(current, document);
        if (shadowPath.length > 0) {
          const path = [outer].concat(shadowPath);
          return { selector: path.join(' >> shadow >> '), selector_kind: 'shadow', shadow_path: path, xpath: null };
        }
        return { selector: selectorPath(element, document), selector_kind: 'css', shadow_path: [], xpath: xpathForElement(element) };
      };

      const whitelistedAttributes = (element) => {
        const keys = ['id', 'class', 'name', 'type', 'href', 'role', 'aria-label', 'title', 'alt', 'data-testid', 'data-test', 'data-cy'];
        const out = {};
        for (const key of keys) {
          const value = element.getAttribute && element.getAttribute(key);
          if (value) out[key] = sanitizedText(value, 300);
        }
        return out;
      };

      const payloadFor = (element, event, pickedViaActiveMode) => {
        const selector = selectorDescription(element);
        const rect = element.getBoundingClientRect();
        const attributes = whitelistedAttributes(element);
        const text = sanitizedText(element.innerText || element.textContent || element.getAttribute('aria-label') || element.getAttribute('title') || '', 500);
        return {
          selector: selector.selector,
          selector_kind: selector.selector_kind,
          shadow_path: selector.shadow_path,
          xpath: selector.xpath,
          text: text,
          tag: (element.localName || 'element').toLowerCase(),
          role: element.getAttribute('role') || '',
          label: element.getAttribute('aria-label') || element.getAttribute('title') || element.getAttribute('alt') || '',
          attributes: attributes,
          url: String(document.URL || ''),
          title: String(document.title || ''),
          frame_url: String(window.location && window.location.href || ''),
          rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          activation: pickedViaActiveMode ? 'armed' : 'option',
          pointer: { x: event.clientX, y: event.clientY },
          timestamp_ms: Date.now()
        };
      };

      const setActive = (active) => {
        state.active = !!active;
        if (!state.active) {
          hideOverlay();
        }
        return state.active;
      };

      Object.defineProperty(window, '__cmuxElementPicker', {
        value: {
          setActive,
          isActive: () => !!state.active
        },
        writable: false,
        configurable: false,
        enumerable: false
      });

      document.addEventListener('mousemove', (event) => {
        if (!state.active && !event.altKey) {
          hideOverlay();
          return;
        }
        showOverlay(elementFromEvent(event), false);
      }, true);

      document.addEventListener('click', (event) => {
        const pickedViaActiveMode = !!state.active;
        if (!pickedViaActiveMode && !event.altKey) return;
        const element = elementFromEvent(event);
        if (!element) return;
        event.preventDefault();
        event.stopPropagation();
        showOverlay(element, true);
        setActive(false);
        try {
          const handler = getHandler();
          if (handler) handler.postMessage(payloadFor(element, event, pickedViaActiveMode));
        } catch (_) {}
      }, true);

      window.addEventListener('blur', hideOverlay, true);
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) hideOverlay();
      }, true);

      if (window.__cmuxElementPickerPendingActive === true) {
        setActive(true);
      }

      return true;
    })()
    """
}

final class BrowserElementPickerMessageHandler: NSObject, WKScriptMessageHandler {
    weak var panel: BrowserPanel?
    private let webViewInstanceID: UUID

    init(panel: BrowserPanel, webViewInstanceID: UUID) {
        self.panel = panel
        self.webViewInstanceID = webViewInstanceID
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BrowserElementPickerBridge.messageHandlerName,
              let body = message.body as? [String: Any] else {
            return
        }
        Task { @MainActor [weak panel] in
            panel?.handleElementPickerMessage(body, webViewInstanceID: webViewInstanceID)
        }
    }
}

struct BrowserElementPickerNativeClick {
    let uptime: TimeInterval
    let optionKey: Bool
    let pickerWasActive: Bool
}

extension BrowserPanel {
    func installElementPickerMessageHandler(for webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: BrowserElementPickerBridge.messageHandlerName)
        controller.add(
            BrowserElementPickerMessageHandler(panel: self, webViewInstanceID: webViewInstanceID),
            name: BrowserElementPickerBridge.messageHandlerName
        )
    }

    func uninstallElementPickerMessageHandler(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserElementPickerBridge.messageHandlerName
        )
    }

    func toggleElementPicker() {
        setElementPickerActive(!isElementPickerActive)
    }

    func setElementPickerActive(_ active: Bool) {
        guard isElementPickerActive != active else {
            syncElementPickerActiveStateToPage()
            return
        }
        isElementPickerActive = active
        syncElementPickerActiveStateToPage()
    }

    func noteElementPickerNativeMouseDown(_ event: NSEvent) {
        let optionKey = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        guard optionKey || isElementPickerActive else { return }
        elementPickerLastNativeClick = BrowserElementPickerNativeClick(
            uptime: ProcessInfo.processInfo.systemUptime,
            optionKey: optionKey,
            pickerWasActive: isElementPickerActive
        )
    }

    func handleElementPickerMessage(_ body: [String: Any], webViewInstanceID messageWebViewInstanceID: UUID) {
        guard messageWebViewInstanceID == webViewInstanceID else { return }
        guard consumeElementPickerNativeClickAuthorization() else {
#if DEBUG
            cmuxDebugLog("browser.elementPicker.drop panel=\(id.uuidString.prefix(5)) reason=noNativeClick")
#endif
            return
        }
        guard let candidate = BrowserElementPick.make(
            body: body,
            surfaceId: id,
            workspaceId: workspaceId,
            pageURL: currentURL ?? webView.url,
            pageTitle: pageTitle
        ) else {
            setElementPickerActive(false)
            return
        }
        let pick = BrowserElementPickStore.shared.record(candidate)
        setElementPickerActive(false)
        NotificationCenter.default.post(
            name: .browserElementPicked,
            object: self,
            userInfo: [BrowserElementPickNotificationKey.pick: pick]
        )
    }

    func syncElementPickerActiveStateToPage() {
        let script = BrowserElementPickerBridge.setActiveScript(isElementPickerActive)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func consumeElementPickerNativeClickAuthorization() -> Bool {
        guard let click = elementPickerLastNativeClick else { return false }
        elementPickerLastNativeClick = nil
        let elapsed = ProcessInfo.processInfo.systemUptime - click.uptime
        guard elapsed >= 0, elapsed <= 1.0 else { return false }
        return click.optionKey || click.pickerWasActive
    }
}
