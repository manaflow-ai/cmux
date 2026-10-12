import AppKit
import Foundation
import WebKit

/// Owns the isolated browser picker bridge and its native user-gesture authorization.
@MainActor
final class BrowserElementPicker: NSObject, WKScriptMessageHandler {
    struct PickedElement: Sendable, Equatable {
        let xpath: String?
        let selector: String
        let shadowHosts: [String]
        let text: String
        let tag: String
        let timestampMs: Double

        /// Locators are rejected rather than truncated, preserving their meaning.
        init?(body: [String: Any], timestampMs: Double) {
            guard let selector = body["selector"] as? String,
                  let hosts = body["shadow_hosts"] as? [String], hosts.count <= 32,
                  let text = body["text"] as? String, text.utf8.count <= 4096,
                  let tag = body["tag"] as? String, !tag.isEmpty, tag.utf8.count <= 256,
                  Self.validLocator(selector), hosts.allSatisfy(Self.validLocator),
                  hosts.reduce(selector.utf8.count, { $0 + $1.utf8.count }) <= 4000 else { return nil }
            let xpath = body["xpath"] as? String
            guard (hosts.isEmpty && xpath.map(Self.validLocator) == true)
                    || (!hosts.isEmpty && body["xpath"] is NSNull) else { return nil }
            self.xpath = xpath
            self.selector = selector
            self.shadowHosts = hosts
            self.text = String(Self.filtered(text).prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            self.tag = String(Self.filtered(tag).prefix(64))
            self.timestampMs = timestampMs
        }

        var jsonObject: [String: Any] {
            ["xpath": xpath as Any? ?? NSNull(), "selector": selector,
             "shadow_hosts": shadowHosts, "text": text, "tag": tag, "timestamp_ms": timestampMs]
        }

        /// Filtering limits terminal control effects; printable content remains untrusted.
        var summary: String {
            let location = xpath ?? (shadowHosts + [selector]).joined(separator: " >>> ")
            return "[picked] \(location)" + (text.isEmpty ? "" : " \"\(text)\"")
        }

        private static func validLocator(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 2000 && filtered(value) == value
        }

        private static func filtered(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
                let v = scalar.value
                return v >= 0x20 && !(0x7F...0x9F).contains(v)
                    && !(0x200B...0x200F).contains(v) && !(0x2028...0x202E).contains(v)
                    && !(0x2066...0x2069).contains(v) && v != 0xFEFF
            }))
        }
    }

    struct NativeClickAuthorization {
        private var armedAt: TimeInterval?
        mutating func arm(at time: TimeInterval) { armedAt = time }
        mutating func invalidate() { armedAt = nil }
        mutating func consume(at time: TimeInterval) -> Bool {
            guard let armedAt else { return false }
            self.armedAt = nil
            let elapsed = time - armedAt
            return elapsed >= 0 && elapsed < 1
        }
    }

    static let contentWorld = WKContentWorld.world(name: "cmuxElementPicker")
    static let messageHandlerName = "cmuxPointer"
    weak var associatedWebView: WKWebView?
    private let onPick: @MainActor (PickedElement) -> Void
    private var generation: UInt64 = 0
    private var enabled = false
    private var authorization = NativeClickAuthorization()
    // The immutable handle crosses only to a main-actor cleanup task; AppKit access stays on main.
    private struct EventMonitorToken: @unchecked Sendable {
        private let rawValue: Any

        @MainActor init(_ rawValue: Any) { self.rawValue = rawValue }
        @MainActor func remove() { NSEvent.removeMonitor(rawValue) }
    }

    private var eventMonitor: EventMonitorToken?

    init(webView: WKWebView, onPick: @escaping @MainActor (PickedElement) -> Void) {
        associatedWebView = webView
        self.onPick = onPick
        super.init()
        webView.configuration.userContentController.add(self, contentWorld: Self.contentWorld, name: Self.messageHandlerName)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.refreshModifierState(event.modifierFlags)
                return event
            }
            self.authorization.invalidate()
            let modifiers = event.modifierFlags.intersection([.option, .command, .control, .shift])
            guard self.enabled, modifiers == .option,
                  let view = self.associatedWebView, let window = view.window,
                  event.window === window, let contentView = window.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            guard let hit = contentView.hitTest(point), hit === view || hit.isDescendant(of: view) else { return event }
            self.authorization.arm(at: ProcessInfo.processInfo.systemUptime)
            return event
        }
        eventMonitor = monitor.map(EventMonitorToken.init)
    }

    deinit {
        if let eventMonitor {
            Task { @MainActor in eventMonitor.remove() }
        }
    }

    func configure(enabled: Bool, generation: UInt64) {
        self.enabled = enabled
        self.generation = generation
        authorization.invalidate()
        evaluate("globalThis.__cmuxElementPicker?.configure(\(enabled ? "true" : "false"), '\(generation)')")
    }

    func invalidateAuthorization() {
        authorization.invalidate()
    }

    func detach() {
        enabled = false
        authorization.invalidate()
        eventMonitor?.remove()
        eventMonitor = nil
        associatedWebView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName, contentWorld: Self.contentWorld
        )
        evaluate("globalThis.__cmuxElementPicker?.configure(false, 'detached')")
        associatedWebView = nil
    }

    private func refreshModifierState(_ flags: NSEvent.ModifierFlags) {
        let active = flags.intersection([.option, .command, .control, .shift]) == .option
        evaluate("globalThis.__cmuxElementPicker?.modifierChanged(\(active ? "true" : "false"))")
    }

    private func evaluate(_ source: String) {
        associatedWebView?.evaluateJavaScript(source, in: nil, in: Self.contentWorld) { _ in }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard enabled, message.name == Self.messageHandlerName,
              message.webView === associatedWebView, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], body.count <= 8,
              body["generation"] as? String == String(generation),
              let element = PickedElement(body: body, timestampMs: Date().timeIntervalSince1970 * 1000),
              authorization.consume(at: ProcessInfo.processInfo.systemUptime) else { return }
        onPick(element)
    }

    static let scriptSource = #"""
    (() => {
      'use strict';
      if (globalThis.__cmuxElementPicker) return;
      let enabled = false, generation = '', modifier = false, target = null, host = null, box = null;
      const hide = () => { if (host) host.style.setProperty('display', 'none', 'important'); };
      const ensureOverlay = () => {
        if (host?.isConnected) return;
        host = document.createElement('cmux-element-picker-overlay');
        host.setAttribute('aria-hidden', 'true');
        host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;pointer-events:none!important;z-index:2147483647!important;display:none!important;';
        const root = host.attachShadow({mode:'closed'});
        box = document.createElement('div');
        box.style.cssText = 'position:absolute;box-sizing:border-box;pointer-events:none;border:2px solid #4F46E5;background:rgba(79,70,229,.1);border-radius:3px;';
        root.appendChild(box);
        document.documentElement.appendChild(host);
      };
      const show = (picked = false) => {
        if (!enabled || !modifier || !(target instanceof Element) || !target.isConnected) { hide(); return; }
        ensureOverlay();
        const r = target.getBoundingClientRect();
        host.style.setProperty('display', 'block', 'important');
        Object.assign(box.style, {top:r.top+'px',left:r.left+'px',width:r.width+'px',height:r.height+'px',
          borderColor:picked?'#16A34A':'#4F46E5',background:picked?'rgba(22,163,74,.15)':'rgba(79,70,229,.1)'});
      };
      const eventElement = e => {
        const first = e.composedPath?.()[0] || e.target;
        return first instanceof Element ? first : first?.parentElement;
      };
      const isPick = e => e.isTrusted && e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey && e.button === 0;
      const cssPath = element => {
        const parts = [];
        for (let current = element; current; current = current.parentElement) {
          let index = 1;
          for (let sibling = current.previousElementSibling; sibling; sibling = sibling.previousElementSibling) index++;
          parts.unshift('*:nth-child('+index+')');
          if (parts.join(' > ').length > 2000) break;
        }
        return parts.join(' > ');
      };
      const literal = value => {
        if (!value.includes("'")) return "'"+value+"'";
        if (!value.includes('"')) return '"'+value+'"';
        return 'concat('+value.split("'").map(part=>"'"+part+"'").join(',"\'",')+')';
      };
      const xpathFor = element => {
        const parts = [];
        for (let current = element; current; current = current.parentElement) {
          let index = 1;
          for (let sibling = current.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
            if (sibling.localName === current.localName && sibling.namespaceURI === current.namespaceURI) index++;
          }
          const test = current.namespaceURI === 'http://www.w3.org/1999/xhtml' && /^[A-Za-z_][A-Za-z0-9_.-]*$/.test(current.localName)
            ? current.localName : '*[local-name()='+literal(current.localName)+' and namespace-uri()='+literal(current.namespaceURI || '')+']';
          parts.unshift(test+'['+index+']');
          if (parts.join('/').length > 2000) break;
        }
        return '/'+parts.join('/');
      };
      const locators = element => {
        const selector = cssPath(element), hosts = [];
        let root = element.getRootNode();
        while (root instanceof ShadowRoot) {
          hosts.unshift(cssPath(root.host));
          if (hosts.length > 32) break;
          root = root.host.getRootNode();
        }
        return {selector, shadow_hosts:hosts, xpath:hosts.length ? null : xpathFor(element)};
      };
      const boundedText = element => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let text = '', node, count = 0;
        while (text.length < 1000 && count++ < 256 && (node = walker.nextNode())) text += node.data.slice(0, 1000-text.length);
        return text.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g,'').slice(0,200).trim();
      };
      const describeElement = element => ({...locators(element),text:boundedText(element),tag:element.localName.slice(0,64)});
      document.addEventListener('pointermove', e => {
        if (!e.isTrusted) return;
        target = eventElement(e); modifier = e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey;
        show();
      }, true);
      document.addEventListener('pointerleave', e => { if (e.isTrusted) { target = null; hide(); } }, true);
      for (const name of ['pointerdown','pointerup']) document.addEventListener(name, e => {
        if (!enabled || !isPick(e)) return;
        e.preventDefault(); e.stopImmediatePropagation();
      }, true);
      document.addEventListener('click', e => {
        if (!enabled || !isPick(e)) return;
        const element = eventElement(e);
        if (!(element instanceof Element) || !element.isConnected) return;
        const data = describeElement(element);
        const byteLength = value => new TextEncoder().encode(value).length;
        if (byteLength(data.selector) > 2000 || data.shadow_hosts.length > 32
            || data.shadow_hosts.some(path=>byteLength(path)>2000) || (data.xpath && byteLength(data.xpath)>2000)
            || data.shadow_hosts.reduce((total,path)=>total+byteLength(path),byteLength(data.selector)) > 4000) return;
        e.preventDefault(); e.stopImmediatePropagation();
        target = element; modifier = true; show(true);
        globalThis.webkit?.messageHandlers?.cmuxPointer?.postMessage({...data,generation});
      }, true);
      document.addEventListener('keydown', e => { if(e.isTrusted) {modifier=e.altKey&&!e.ctrlKey&&!e.metaKey&&!e.shiftKey;show();} }, true);
      document.addEventListener('keyup', e => { if(e.isTrusted) {modifier=e.altKey&&!e.ctrlKey&&!e.metaKey&&!e.shiftKey;show();} }, true);
      globalThis.addEventListener('scroll', () => show(), true);
      globalThis.addEventListener('resize', () => show());
      globalThis.addEventListener('blur', () => {modifier=false;hide();});
      document.addEventListener('visibilitychange', () => {if(document.hidden){modifier=false;hide();}});
      globalThis.__cmuxElementPicker = {
        describeElement,
        configure(active, nextGeneration) {enabled=active;generation=nextGeneration;if(!active){target=null;hide();}},
        modifierChanged(active) {modifier=active;show();}
      };
    })();
    """#
}

typealias BrowserPickedElement = BrowserElementPicker.PickedElement

extension Notification.Name {
    static let browserElementPickerStateDidChange = Notification.Name("browserElementPickerStateDidChange")
}
