public import Foundation

/// The `cmux://extensions` page: cmux's equivalent of `chrome://extensions`.
///
/// The page is static HTML served by a URL scheme handler. It talks to the
/// app through one script message handler whose replies carry the current
/// extension list. The app accepts those messages only from the main frame of
/// the `cmux://extensions` origin, which web content cannot forge, and every
/// action that installs or removes code still asks for native confirmation.
public enum ChromeExtensionsManagerPage {
    public static let scheme = "cmux"
    public static let host = "extensions"
    public static let url = URL(string: "cmux://extensions")!
    public static let messageHandlerName = "cmuxExtensionsPage"

    /// Whether `url` addresses the extensions page or one of its resources.
    public static func isManagerPageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// The extension id of a `cmux://extensions/icon/<id>` request.
    public static func iconExtensionID(for url: URL) -> String? {
        guard isManagerPageURL(url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "icon" else { return nil }
        let id = parts[1]
        guard ChromeExtensionPackage.isExtensionID(id) || isLocalExtensionID(id) else { return nil }
        return id
    }

    /// Ids cmux assigns to extensions loaded from a folder.
    public static func isLocalExtensionID(_ id: String) -> Bool {
        guard id.hasPrefix("local-") else { return false }
        return id.dropFirst("local-".count).allSatisfy { $0.isHexDigit || $0 == "-" } && id.count <= 48
    }

    /// Response headers for every page resource. The page may not be framed,
    /// and it loads nothing from the network.
    public static let responseHeaders: [String: String] = [
        "Content-Security-Policy": "default-src 'none'; img-src cmux: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        "X-Frame-Options": "DENY",
        "Cache-Control": "no-store",
    ]

    /// One installed extension as the page shows it.
    public struct Row: Encodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var version: String
        public var enabled: Bool
        public var running: Bool
        public var fromStore: Bool
        public var hasOptions: Bool
        public var permissions: [String]
        public var errors: [String]

        public init(
            id: String,
            name: String,
            version: String,
            enabled: Bool,
            running: Bool,
            fromStore: Bool,
            hasOptions: Bool,
            permissions: [String],
            errors: [String]
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.enabled = enabled
            self.running = running
            self.fromStore = fromStore
            self.hasOptions = hasOptions
            self.permissions = permissions
            self.errors = errors
        }
    }

    /// The whole page state returned for every request.
    public struct Snapshot: Encodable, Equatable, Sendable {
        public var supported: Bool
        public var busy: String?
        public var lastError: String?
        public var extensions: [Row]

        public init(supported: Bool, busy: String?, lastError: String?, extensions: [Row]) {
            self.supported = supported
            self.busy = busy
            self.lastError = lastError
            self.extensions = extensions
        }
    }

    /// Requests the page can make.
    public enum Request: Equatable, Sendable {
        case snapshot
        case install(String)
        case loadUnpacked
        case setEnabled(id: String, enabled: Bool)
        case remove(id: String)
        case reload(id: String)
        case openOptions(id: String)
        case openStore

        /// Decodes a message body. Unknown shapes return `nil`.
        public init?(messageBody: Any) {
            guard let body = messageBody as? [String: Any], let action = body["action"] as? String else { return nil }
            let id = body["id"] as? String
            switch action {
            case "snapshot": self = .snapshot
            case "install":
                guard let text = body["text"] as? String, text.count <= 2048 else { return nil }
                self = .install(text)
            case "loadUnpacked": self = .loadUnpacked
            case "setEnabled":
                guard let id, let enabled = body["enabled"] as? Bool else { return nil }
                self = .setEnabled(id: id, enabled: enabled)
            case "remove":
                guard let id else { return nil }
                self = .remove(id: id)
            case "reload":
                guard let id else { return nil }
                self = .reload(id: id)
            case "openOptions":
                guard let id else { return nil }
                self = .openOptions(id: id)
            case "openStore": self = .openStore
            default: return nil
            }
        }
    }

    /// Localized page text, supplied by the app.
    public struct Strings: Encodable, Sendable {
        public var title: String
        public var subtitle: String
        public var installPlaceholder: String
        public var installButton: String
        public var loadUnpacked: String
        public var openStore: String
        public var empty: String
        public var unsupported: String
        public var enabled: String
        public var options: String
        public var reload: String
        public var remove: String
        public var fromStore: String
        public var unpacked: String
        public var notRunning: String
        public var permissions: String
        public var noPermissions: String
        public var installing: String
        public var id: String

        public init(
            title: String,
            subtitle: String,
            installPlaceholder: String,
            installButton: String,
            loadUnpacked: String,
            openStore: String,
            empty: String,
            unsupported: String,
            enabled: String,
            options: String,
            reload: String,
            remove: String,
            fromStore: String,
            unpacked: String,
            notRunning: String,
            permissions: String,
            noPermissions: String,
            installing: String,
            id: String
        ) {
            self.title = title
            self.subtitle = subtitle
            self.installPlaceholder = installPlaceholder
            self.installButton = installButton
            self.loadUnpacked = loadUnpacked
            self.openStore = openStore
            self.empty = empty
            self.unsupported = unsupported
            self.enabled = enabled
            self.options = options
            self.reload = reload
            self.remove = remove
            self.fromStore = fromStore
            self.unpacked = unpacked
            self.notRunning = notRunning
            self.permissions = permissions
            self.noPermissions = noPermissions
            self.installing = installing
            self.id = id
        }
    }

    /// The page HTML. `layoutDirection` is `"ltr"` or `"rtl"`.
    public static func html(strings: Strings, languageCode: String, layoutDirection: String) -> String {
        let stringsJSON = (try? JSONEncoder().encode(strings)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let lang = languageCode.filter { $0.isLetter || $0 == "-" }
        let dir = layoutDirection == "rtl" ? "rtl" : "ltr"
        return """
        <!doctype html>
        <html lang="\(lang)" dir="\(dir)">
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title></title>
        <style>
          :root { --bg: #ffffff; --card: #f6f6f7; --ink: #1d1d1f; --muted: #6e6e73; --line: rgba(0,0,0,.1); --accent: #0a66ff; --danger: #d70015; }
          @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --card: #2c2c2e; --ink: #f5f5f7; --muted: #a1a1a6; --line: rgba(255,255,255,.12); --accent: #409cff; --danger: #ff453a; } }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--bg); color: var(--ink); font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
          main { max-width: 760px; margin: 0 auto; padding: 32px 20px 48px; }
          h1 { font-size: 22px; font-weight: 600; margin: 0 0 4px; }
          .sub { color: var(--muted); margin: 0 0 20px; }
          .bar { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }
          input { flex: 1 1 280px; min-width: 0; padding: 7px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--card); color: var(--ink); font: inherit; }
          button { padding: 6px 12px; border-radius: 8px; border: 1px solid var(--line); background: var(--card); color: var(--ink); font: inherit; cursor: pointer; }
          button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
          button.danger { color: var(--danger); }
          button:disabled { opacity: .5; cursor: default; }
          .error { color: var(--danger); margin: 8px 0; white-space: pre-wrap; }
          .empty { color: var(--muted); padding: 24px 0; }
          .list { display: grid; gap: 10px; margin-top: 16px; }
          .card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px; display: grid; grid-template-columns: 40px 1fr auto; gap: 12px; align-items: start; }
          .card img { width: 40px; height: 40px; border-radius: 8px; }
          .name { font-weight: 600; font-size: 14px; }
          .meta { color: var(--muted); margin-top: 2px; word-break: break-all; }
          .perms { margin: 8px 0 0; padding-inline-start: 18px; color: var(--muted); }
          .actions { display: flex; gap: 6px; margin-top: 10px; flex-wrap: wrap; }
          label.toggle { display: flex; gap: 6px; align-items: center; white-space: nowrap; }
        </style>
        </head>
        <body>
        <main>
          <h1 id="title"></h1>
          <p class="sub" id="subtitle"></p>
          <div class="bar">
            <input id="install-text" autocomplete="off" spellcheck="false">
            <button id="install" class="primary"></button>
          </div>
          <div class="bar">
            <button id="load-unpacked"></button>
            <button id="open-store"></button>
          </div>
          <div class="error" id="error" hidden></div>
          <div id="list" class="list"></div>
        </main>
        <script>
        (function () {
          'use strict';
          var S = \(stringsJSON);
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName);
          var $ = function (id) { return document.getElementById(id); };
          document.title = S.title;
          $('title').textContent = S.title;
          $('subtitle').textContent = S.subtitle;
          $('install-text').placeholder = S.installPlaceholder;
          $('install').textContent = S.installButton;
          $('load-unpacked').textContent = S.loadUnpacked;
          $('open-store').textContent = S.openStore;

          function send(message) {
            if (!handler) return Promise.resolve(null);
            return handler.postMessage(message).then(render, function (e) { showError(String(e)); });
          }

          function showError(text) {
            $('error').hidden = !text;
            $('error').textContent = text || '';
          }

          function el(tag, attrs, text) {
            var node = document.createElement(tag);
            Object.keys(attrs || {}).forEach(function (k) { node.setAttribute(k, attrs[k]); });
            if (text != null) node.textContent = text;
            return node;
          }

          function button(label, onClick, cls) {
            var b = el('button', cls ? { class: cls } : {}, label);
            b.addEventListener('click', onClick);
            return b;
          }

          function render(state) {
            if (!state) return;
            showError(state.lastError);
            var busy = !!state.busy;
            $('install').disabled = busy || !state.supported;
            $('install').textContent = busy ? S.installing : S.installButton;
            $('load-unpacked').disabled = busy || !state.supported;
            var list = $('list');
            list.textContent = '';
            if (!state.supported) { list.appendChild(el('div', { class: 'empty' }, S.unsupported)); return; }
            if (!state.extensions.length) { list.appendChild(el('div', { class: 'empty' }, S.empty)); return; }
            state.extensions.forEach(function (x) {
              var card = el('div', { class: 'card', 'data-extension-id': x.id });
              card.appendChild(el('img', { src: 'cmux://extensions/icon/' + x.id, alt: '' }));
              var body = el('div');
              body.appendChild(el('div', { class: 'name' }, x.name));
              var meta = x.version + ' · ' + (x.fromStore ? S.fromStore : S.unpacked) + ' · ' + S.id + ' ' + x.id;
              if (x.enabled && !x.running) meta += ' · ' + S.notRunning;
              body.appendChild(el('div', { class: 'meta' }, meta));
              var perms = el('ul', { class: 'perms', 'aria-label': S.permissions });
              (x.permissions.length ? x.permissions : [S.noPermissions]).forEach(function (p) { perms.appendChild(el('li', {}, p)); });
              body.appendChild(perms);
              x.errors.forEach(function (e) { body.appendChild(el('div', { class: 'error' }, e)); });
              var actions = el('div', { class: 'actions' });
              if (x.hasOptions) actions.appendChild(button(S.options, function () { send({ action: 'openOptions', id: x.id }); }));
              if (!x.fromStore) actions.appendChild(button(S.reload, function () { send({ action: 'reload', id: x.id }); }));
              actions.appendChild(button(S.remove, function () { send({ action: 'remove', id: x.id }); }, 'danger'));
              body.appendChild(actions);
              card.appendChild(body);
              var toggle = el('label', { class: 'toggle' });
              var box = el('input', { type: 'checkbox' });
              box.checked = x.enabled;
              box.addEventListener('change', function () { send({ action: 'setEnabled', id: x.id, enabled: box.checked }); });
              toggle.appendChild(box);
              toggle.appendChild(document.createTextNode(S.enabled));
              card.appendChild(toggle);
              list.appendChild(card);
            });
          }

          $('install').addEventListener('click', function () {
            var text = $('install-text').value.trim();
            if (!text) return;
            send({ action: 'install', text: text }).then(function () { $('install-text').value = ''; });
          });
          $('install-text').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('install').click(); });
          $('load-unpacked').addEventListener('click', function () { send({ action: 'loadUnpacked' }); });
          $('open-store').addEventListener('click', function () { send({ action: 'openStore' }); });
          window.__cmuxExtensionsPageRender = render;
          document.addEventListener('visibilitychange', function () { if (!document.hidden) send({ action: 'snapshot' }); });
          send({ action: 'snapshot' });
        })();
        </script>
        </body>
        </html>
        """
    }
}
