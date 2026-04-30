import Foundation

enum CMUXRemoteWebClient {
    struct Asset {
        let body: String
        let contentType: String
    }

    static func asset(path: String) -> Asset? {
        switch path {
        case "/", "/remote":
            return Asset(body: html, contentType: "text/html; charset=utf-8")
        case "/remote/app.js":
            return Asset(body: javascript, contentType: "application/javascript; charset=utf-8")
        case "/remote/strings.json":
            return Asset(body: stringsJSON, contentType: "application/json; charset=utf-8")
        case "/remote/styles.css":
            return Asset(body: css, contentType: "text/css; charset=utf-8")
        case "/remote/manifest.webmanifest":
            return Asset(body: manifest, contentType: "application/manifest+json; charset=utf-8")
        case "/remote/icon.svg", "/remote/maskable-icon.svg", "/remote/icon-maskable.svg":
            return Asset(body: iconSVG, contentType: "image/svg+xml; charset=utf-8")
        default:
            return nil
        }
    }

    private struct LocalizedEntry {
        let id: String
        let key: StaticString
        let defaultValue: String.LocalizationValue

        init(_ id: String, key: StaticString, defaultValue: String.LocalizationValue) {
            self.id = id
            self.key = key
            self.defaultValue = defaultValue
        }
    }

    private static let localizedEntries: [LocalizedEntry] = [
        LocalizedEntry("appTitle", key: "remoteAccess.web.title", defaultValue: "cmux remote"),
        LocalizedEntry("productName", key: "remoteAccess.web.appName", defaultValue: "cmux"),
        LocalizedEntry("connectSubtitle", key: "remoteAccess.web.subtitle", defaultValue: "Connect to the running cmux app on this Mac."),
        LocalizedEntry("tokenLabel", key: "remoteAccess.web.token.label", defaultValue: "Remote access token"),
        LocalizedEntry("tokenPlaceholder", key: "remoteAccess.web.token.placeholder", defaultValue: "Paste token"),
        LocalizedEntry("connectButton", key: "remoteAccess.web.token.connect", defaultValue: "Connect"),
        LocalizedEntry("tokenHint", key: "remoteAccess.web.token.hint", defaultValue: "The token stays in this browser. Use Forget to remove it."),
        LocalizedEntry("status.disconnected", key: "remoteAccess.web.status.disconnected", defaultValue: "Disconnected"),
        LocalizedEntry("status.refreshing", key: "remoteAccess.web.status.refreshing", defaultValue: "Refreshing..."),
        LocalizedEntry("status.connected", key: "remoteAccess.web.status.connected", defaultValue: "Connected"),
        LocalizedEntry("refreshButton", key: "remoteAccess.web.action.refresh", defaultValue: "Refresh"),
        LocalizedEntry("forgetButton", key: "remoteAccess.web.action.forget", defaultValue: "Forget"),
        LocalizedEntry("sessionsTitle", key: "remoteAccess.web.sessions.title", defaultValue: "Sessions"),
        LocalizedEntry("noTerminalSelected", key: "remoteAccess.web.terminal.noSelectionTitle", defaultValue: "No terminal selected"),
        LocalizedEntry("selectTerminal", key: "remoteAccess.web.terminal.noSelectionMeta", defaultValue: "Select a terminal surface."),
        LocalizedEntry("readButton", key: "remoteAccess.web.action.read", defaultValue: "Read"),
        LocalizedEntry("inputPlaceholder", key: "remoteAccess.web.terminal.inputPlaceholder", defaultValue: "Type input"),
        LocalizedEntry("sendButton", key: "remoteAccess.web.action.send", defaultValue: "Send"),
        LocalizedEntry("terminalOutputLabel", key: "remoteAccess.web.terminal.outputLabel", defaultValue: "Terminal output"),
        LocalizedEntry("terminalKeysLabel", key: "remoteAccess.web.terminal.keysLabel", defaultValue: "Terminal keys"),
        LocalizedEntry("quickKeysLabel", key: "remoteAccess.web.terminal.quickKeysLabel", defaultValue: "Quick keys"),
        LocalizedEntry("terminalEmptyOutput", key: "remoteAccess.web.terminal.emptyOutput", defaultValue: "No output yet. Press Read to fetch the terminal."),
        LocalizedEntry("key.enter", key: "remoteAccess.web.key.enter", defaultValue: "Enter"),
        LocalizedEntry("key.escape", key: "remoteAccess.web.key.escape", defaultValue: "Esc"),
        LocalizedEntry("key.ctrlC", key: "remoteAccess.web.key.ctrlC", defaultValue: "Ctrl-C"),
        LocalizedEntry("key.tab", key: "remoteAccess.web.key.tab", defaultValue: "Tab"),
        LocalizedEntry("key.up", key: "remoteAccess.web.key.up", defaultValue: "Up"),
        LocalizedEntry("key.down", key: "remoteAccess.web.key.down", defaultValue: "Down"),
        LocalizedEntry("key.left", key: "remoteAccess.web.key.left", defaultValue: "Left"),
        LocalizedEntry("key.right", key: "remoteAccess.web.key.right", defaultValue: "Right"),
        LocalizedEntry("key.backspace", key: "remoteAccess.web.key.backspace", defaultValue: "Backspace"),
        LocalizedEntry("error.requestFailed", key: "remoteAccess.web.error.requestFailed", defaultValue: "Request failed ({status})"),
        LocalizedEntry("error.tokenRejected", key: "remoteAccess.web.error.tokenRejected", defaultValue: "Token was rejected."),
        LocalizedEntry("error.snapshotFailed", key: "remoteAccess.web.error.snapshotFailed", defaultValue: "Snapshot failed ({status})"),
        LocalizedEntry("tree.noWindows", key: "remoteAccess.web.sessions.noWindows", defaultValue: "No windows found."),
        LocalizedEntry("tree.workspaceFallback", key: "remoteAccess.web.workspace.fallback", defaultValue: "Workspace"),
        LocalizedEntry("tree.selected", key: "remoteAccess.web.workspace.selected", defaultValue: "selected"),
        LocalizedEntry("tree.windowPanes", key: "remoteAccess.web.workspace.meta", defaultValue: "window {window} - {panes} panes"),
        LocalizedEntry("tree.surfaceFallback", key: "remoteAccess.web.surface.fallback", defaultValue: "Surface"),
        LocalizedEntry("tree.surfaceTypeFallback", key: "remoteAccess.web.surface.typeFallback", defaultValue: "surface"),
        LocalizedEntry("tree.focusedSurface", key: "remoteAccess.web.surface.focused", defaultValue: "focused"),
        LocalizedEntry("terminalFallback", key: "remoteAccess.web.terminal.fallback", defaultValue: "Terminal"),
    ]

    private static var localizedStrings: [String: String] {
        Dictionary(uniqueKeysWithValues: localizedEntries.map { entry in
            (entry.id, String(localized: entry.key, defaultValue: entry.defaultValue))
        })
    }

    private static var stringsJSON: String {
        jsonString(localizedStrings)
    }

    private static func jsonString(_ payload: Any) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func htmlText(_ value: String?) -> String {
        htmlEscaped(value ?? "")
    }

    private static func htmlAttribute(_ value: String?) -> String {
        htmlEscaped(value ?? "")
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static var html: String {
        let strings = localizedStrings
        return #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#121417">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-title" content="\#(htmlAttribute(strings["productName"]))">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <title>\#(htmlText(strings["appTitle"]))</title>
  <link rel="manifest" href="/remote/manifest.webmanifest">
  <link rel="apple-touch-icon" href="/remote/icon.svg">
  <link rel="icon" href="/remote/icon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/remote/styles.css">
</head>
<body>
  <main id="app" class="shell">
    <section id="token-view" class="token-panel">
      <div class="brand-row">
        <div class="mark" aria-hidden="true">c</div>
        <div>
          <h1 data-i18n="appTitle">\#(htmlText(strings["appTitle"]))</h1>
          <p data-i18n="connectSubtitle">\#(htmlText(strings["connectSubtitle"]))</p>
        </div>
      </div>
      <form id="token-form" class="token-form">
        <label for="token-input" data-i18n="tokenLabel">\#(htmlText(strings["tokenLabel"]))</label>
        <input id="token-input" name="token" type="password" autocomplete="current-password" spellcheck="false" placeholder="\#(htmlAttribute(strings["tokenPlaceholder"]))" data-i18n-placeholder="tokenPlaceholder">
        <button type="submit" data-i18n="connectButton">\#(htmlText(strings["connectButton"]))</button>
      </form>
      <p class="hint" data-i18n="tokenHint">\#(htmlText(strings["tokenHint"]))</p>
    </section>

    <section id="remote-view" class="remote-view" hidden>
      <header class="topbar">
        <div class="topbar-brand">
          <div class="mark small" aria-hidden="true">c</div>
          <div>
            <h1 data-i18n="productName">\#(htmlText(strings["productName"]))</h1>
            <p id="status-line" class="status-pill" data-i18n="status.disconnected">\#(htmlText(strings["status.disconnected"]))</p>
          </div>
        </div>
        <div class="top-actions">
          <button id="refresh-button" type="button" data-i18n="refreshButton">\#(htmlText(strings["refreshButton"]))</button>
          <button id="forget-button" type="button" class="ghost" data-i18n="forgetButton">\#(htmlText(strings["forgetButton"]))</button>
        </div>
      </header>

      <section class="layout">
        <aside class="nav-panel">
          <div class="panel-title">
            <span data-i18n="sessionsTitle">\#(htmlText(strings["sessionsTitle"]))</span>
          </div>
          <div id="tree-list" class="tree-list"></div>
        </aside>

        <section class="terminal-panel">
          <div class="terminal-head">
            <div>
              <div id="terminal-title" class="terminal-title" data-i18n="noTerminalSelected">\#(htmlText(strings["noTerminalSelected"]))</div>
              <div id="terminal-meta" class="terminal-meta" data-i18n="selectTerminal">\#(htmlText(strings["selectTerminal"]))</div>
            </div>
          </div>

          <div class="terminal-frame">
            <div class="terminal-toolbar">
              <span data-i18n="terminalOutputLabel">\#(htmlText(strings["terminalOutputLabel"]))</span>
              <button id="read-button" type="button" class="ghost" data-i18n="readButton">\#(htmlText(strings["readButton"]))</button>
            </div>
            <pre id="terminal-output" class="terminal-output empty" aria-live="polite" aria-label="\#(htmlAttribute(strings["terminalOutputLabel"]))" data-i18n-aria-label="terminalOutputLabel">\#(htmlText(strings["terminalEmptyOutput"]))</pre>
          </div>

          <div class="composer-panel">
            <form id="send-form" class="send-form">
              <textarea id="send-input" rows="2" spellcheck="false" placeholder="\#(htmlAttribute(strings["inputPlaceholder"]))" data-i18n-placeholder="inputPlaceholder"></textarea>
              <button type="submit" data-i18n="sendButton">\#(htmlText(strings["sendButton"]))</button>
            </form>
            <div class="key-section">
              <div class="panel-title compact" data-i18n="quickKeysLabel">\#(htmlText(strings["quickKeysLabel"]))</div>
              <div class="key-grid" aria-label="\#(htmlAttribute(strings["terminalKeysLabel"]))" data-i18n-aria-label="terminalKeysLabel">
                <button type="button" data-key="enter" data-i18n="key.enter">\#(htmlText(strings["key.enter"]))</button>
                <button type="button" data-key="escape" data-i18n="key.escape">\#(htmlText(strings["key.escape"]))</button>
                <button type="button" data-key="ctrl-c" data-i18n="key.ctrlC">\#(htmlText(strings["key.ctrlC"]))</button>
                <button type="button" data-key="tab" data-i18n="key.tab">\#(htmlText(strings["key.tab"]))</button>
                <button type="button" data-key="up" data-i18n="key.up">\#(htmlText(strings["key.up"]))</button>
                <button type="button" data-key="down" data-i18n="key.down">\#(htmlText(strings["key.down"]))</button>
                <button type="button" data-key="left" data-i18n="key.left">\#(htmlText(strings["key.left"]))</button>
                <button type="button" data-key="right" data-i18n="key.right">\#(htmlText(strings["key.right"]))</button>
                <button type="button" data-key="backspace" data-i18n="key.backspace">\#(htmlText(strings["key.backspace"]))</button>
              </div>
            </div>
          </div>
        </section>
      </section>
    </section>
  </main>
  <script type="module" src="/remote/app.js"></script>
</body>
</html>
"""#
    }

    private static var manifest: String {
        let strings = localizedStrings
        let payload: [String: Any] = [
            "name": strings["appTitle"] ?? "",
            "short_name": strings["productName"] ?? "",
            "start_url": "/remote",
            "scope": "/",
            "display": "standalone",
            "background_color": "#121417",
            "theme_color": "#121417",
            "icons": [
                [
                    "src": "/remote/icon.svg",
                    "sizes": "any",
                    "type": "image/svg+xml",
                    "purpose": "any",
                ],
                [
                    "src": "/remote/maskable-icon.svg",
                    "sizes": "any",
                    "type": "image/svg+xml",
                    "purpose": "maskable",
                ],
            ],
        ]
        return jsonString(payload)
    }

    private static var iconSVG: String {
        #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="\#(htmlAttribute(localizedStrings["productName"]))">
  <rect width="128" height="128" rx="28" fill="#121417"/>
  <path d="M32 42c0-7 6-13 13-13h38c7 0 13 6 13 13v44c0 7-6 13-13 13H45c-7 0-13-6-13-13V42Z" fill="#f7f2e8"/>
  <path d="M52 76 39 64l13-12 6 7-6 5 6 5-6 7Zm23 0-6-7 6-5-6-5 6-7 13 12-13 12Z" fill="#121417"/>
</svg>
"""#
    }

    private static let css = #"""
:root {
  color-scheme: dark;
  --bg: #0b0d10;
  --bg-raised: #101317;
  --panel: #15191f;
  --panel-2: #1d232b;
  --terminal: #050608;
  --text: #f2efe7;
  --muted: #8d98a7;
  --muted-2: #657182;
  --line: #2a313a;
  --line-strong: #3a4350;
  --accent: #5ee6a8;
  --accent-2: #6bbcff;
  --warning: #f5c76b;
  --danger: #ff7b72;
  --shadow: 0 18px 70px rgba(0, 0, 0, 0.36);
}

* {
  box-sizing: border-box;
}

[hidden] {
  display: none !important;
}

html,
body {
  margin: 0;
  min-height: 100%;
  background:
    radial-gradient(circle at top left, rgba(94, 230, 168, 0.10), transparent 34rem),
    radial-gradient(circle at 85% 8%, rgba(107, 188, 255, 0.08), transparent 30rem),
    var(--bg);
  color: var(--text);
  font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
}

body {
  min-height: 100dvh;
}

button,
input,
textarea {
  font: inherit;
}

button {
  border: 1px solid var(--line);
  background: var(--panel-2);
  color: var(--text);
  border-radius: 8px;
  min-height: 40px;
  padding: 0 13px;
  cursor: pointer;
  transition: border-color 120ms ease, background 120ms ease, color 120ms ease, transform 80ms ease;
}

button:hover:not(:disabled) {
  border-color: var(--line-strong);
  background: #252c36;
}

button:active {
  transform: translateY(1px);
}

button:disabled {
  cursor: not-allowed;
  opacity: 0.48;
}

button.primary,
button[type="submit"] {
  background: var(--accent);
  color: #07120d;
  border-color: transparent;
  font-weight: 700;
}

button.ghost {
  background: rgba(255, 255, 255, 0.02);
}

input,
textarea {
  width: 100%;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #080a0d;
  color: var(--text);
  padding: 12px;
  outline: none;
}

input:focus,
textarea:focus {
  border-color: rgba(94, 230, 168, 0.72);
  box-shadow: 0 0 0 3px rgba(94, 230, 168, 0.12);
}

textarea {
  min-height: 76px;
  resize: vertical;
}

.shell {
  width: min(1280px, 100%);
  margin: 0 auto;
  min-height: 100dvh;
  padding: max(14px, env(safe-area-inset-top)) 14px max(14px, env(safe-area-inset-bottom));
}

.token-panel {
  margin: 11vh auto 0;
  max-width: 460px;
  padding: 22px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: linear-gradient(180deg, rgba(29, 35, 43, 0.98), rgba(18, 22, 27, 0.98));
  box-shadow: var(--shadow);
}

.brand-row {
  display: flex;
  gap: 14px;
  align-items: center;
}

.mark {
  display: grid;
  place-items: center;
  width: 48px;
  height: 48px;
  border-radius: 8px;
  background: var(--accent);
  color: #07120d;
  font-weight: 800;
  font-size: 28px;
}

.mark.small {
  width: 34px;
  height: 34px;
  font-size: 20px;
}

h1,
p {
  margin: 0;
}

h1 {
  font-size: 21px;
  letter-spacing: 0;
}

p,
.hint,
.terminal-meta,
#status-line {
  color: var(--muted);
}

.token-form {
  display: grid;
  gap: 10px;
  margin-top: 22px;
}

.hint {
  margin-top: 12px;
  font-size: 13px;
}

.remote-view {
  min-height: calc(100dvh - max(14px, env(safe-area-inset-top)) - max(14px, env(safe-area-inset-bottom)));
  display: grid;
  grid-template-rows: auto 1fr;
}

.topbar,
.terminal-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.topbar {
  position: sticky;
  top: 0;
  z-index: 5;
  padding: 4px 2px 12px;
  background: linear-gradient(180deg, var(--bg) 72%, rgba(11, 13, 16, 0));
}

.topbar-brand {
  display: flex;
  align-items: center;
  gap: 11px;
}

.top-actions {
  display: flex;
  gap: 8px;
}

.status-pill {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  width: fit-content;
  margin-top: 4px;
  font-size: 12px;
  color: var(--muted);
}

.status-pill::before {
  content: "";
  width: 7px;
  height: 7px;
  border-radius: 999px;
  background: var(--warning);
  box-shadow: 0 0 16px rgba(245, 199, 107, 0.5);
}

.status-pill.error::before {
  background: var(--danger);
  box-shadow: 0 0 16px rgba(255, 123, 114, 0.5);
}

.status-pill.connected::before {
  background: var(--accent);
  box-shadow: 0 0 16px rgba(94, 230, 168, 0.55);
}

.layout {
  display: grid;
  grid-template-columns: minmax(280px, 360px) minmax(0, 1fr);
  gap: 12px;
  min-height: 0;
}

.nav-panel,
.terminal-panel {
  min-width: 0;
  min-height: 0;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: rgba(21, 25, 31, 0.9);
  box-shadow: var(--shadow);
}

.nav-panel {
  padding: 12px;
  overflow: auto;
}

.terminal-panel {
  display: grid;
  grid-template-rows: auto minmax(0, 1fr) auto;
  overflow: hidden;
}

.panel-title {
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  margin-bottom: 8px;
}

.panel-title.compact {
  margin: 0;
}

.tree-list {
  display: grid;
  gap: 8px;
}

.workspace,
.surface-button {
  width: 100%;
  text-align: left;
}

.workspace {
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 9px;
  background: rgba(8, 10, 13, 0.52);
}

.workspace-title {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  font-weight: 700;
  font-size: 13px;
}

.workspace-meta,
.surface-meta {
  color: var(--muted);
  font-size: 12px;
}

.surface-list {
  display: grid;
  gap: 6px;
  margin-top: 8px;
}

.surface-button {
  display: grid;
  gap: 3px;
  min-height: 56px;
  padding: 9px 10px;
  background: rgba(255, 255, 255, 0.025);
}

.surface-button.selected {
  border-color: var(--accent);
  background: rgba(94, 230, 168, 0.09);
  box-shadow: inset 3px 0 0 var(--accent);
}

.surface-button.focused:not(.selected) {
  border-color: rgba(107, 188, 255, 0.45);
}

.surface-button:disabled {
  opacity: 0.58;
}

.surface-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 700;
}

.surface-meta {
  display: flex;
  align-items: center;
  gap: 7px;
}

.surface-meta::before {
  content: "";
  width: 6px;
  height: 6px;
  border-radius: 999px;
  background: var(--muted-2);
}

.surface-button.focused .surface-meta::before {
  background: var(--accent-2);
  box-shadow: 0 0 12px rgba(107, 188, 255, 0.5);
}

.terminal-title {
  font-weight: 800;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.terminal-head {
  min-width: 0;
  padding: 13px 14px;
  border-bottom: 1px solid var(--line);
  background: linear-gradient(180deg, rgba(29, 35, 43, 0.78), rgba(21, 25, 31, 0.92));
}

.terminal-head > div {
  min-width: 0;
}

.terminal-frame {
  min-height: 0;
  display: grid;
  grid-template-rows: auto minmax(0, 1fr);
  background: var(--terminal);
}

.terminal-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  min-height: 42px;
  padding: 8px 10px 8px 14px;
  border-bottom: 1px solid #1a2027;
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.terminal-output {
  min-height: 0;
  height: 100%;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
  margin: 0;
  padding: 14px;
  background:
    linear-gradient(rgba(255, 255, 255, 0.018) 50%, transparent 50%) 0 0 / 100% 2.9em,
    var(--terminal);
  color: #e7dfd3;
  font: 12.5px/1.48 "SF Mono", Menlo, Consolas, monospace;
  tab-size: 2;
}

.terminal-output.empty {
  display: grid;
  place-items: center;
  color: var(--muted-2);
  text-align: center;
}

.composer-panel {
  display: grid;
  gap: 10px;
  padding: 12px;
  border-top: 1px solid var(--line);
  background: rgba(16, 19, 23, 0.98);
}

.send-form {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 8px;
}

.key-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(58px, 1fr));
  gap: 6px;
  margin-top: 8px;
}

.key-grid button {
  min-height: 34px;
  padding: 0 8px;
  color: var(--muted);
  background: #0c0f13;
  font-size: 12px;
}

.error {
  color: var(--danger);
}

@media (max-width: 760px) {
  .shell {
    padding-left: 10px;
    padding-right: 10px;
  }

  .remote-view {
    min-height: auto;
  }

  .topbar {
    position: static;
  }

  .layout {
    grid-template-columns: 1fr;
    min-height: auto;
  }

  .topbar {
    align-items: flex-start;
  }

  .top-actions {
    flex-wrap: wrap;
    justify-content: flex-end;
  }

  .nav-panel {
    max-height: 34dvh;
  }

  .terminal-panel {
    min-height: 62dvh;
  }

  .terminal-output {
    min-height: 34dvh;
  }

  .send-form {
    grid-template-columns: 1fr;
  }

  .key-grid {
    grid-template-columns: repeat(3, 1fr);
  }
}

@media (max-width: 430px) {
  .topbar,
  .terminal-head {
    align-items: flex-start;
  }

  .top-actions {
    width: 100%;
  }

  .top-actions button {
    flex: 1;
  }

  .terminal-output {
    font-size: 12px;
  }
}
"""#

    private static let javascript = #"""
const storageKey = "cmux.remote.token";
let remoteStrings = {};

const els = {
  tokenView: document.getElementById("token-view"),
  remoteView: document.getElementById("remote-view"),
  tokenForm: document.getElementById("token-form"),
  tokenInput: document.getElementById("token-input"),
  statusLine: document.getElementById("status-line"),
  treeList: document.getElementById("tree-list"),
  refreshButton: document.getElementById("refresh-button"),
  forgetButton: document.getElementById("forget-button"),
  terminalTitle: document.getElementById("terminal-title"),
  terminalMeta: document.getElementById("terminal-meta"),
  terminalOutput: document.getElementById("terminal-output"),
  readButton: document.getElementById("read-button"),
  sendForm: document.getElementById("send-form"),
  sendInput: document.getElementById("send-input"),
};

const state = {
  token: "",
  snapshot: null,
  selectedSurface: null,
  polling: null,
};

function t(key) {
  return remoteStrings[key] || key;
}

function format(key, replacements = {}) {
  const named = Object.entries(replacements).reduce(
    (message, [name, value]) => message.split(`{${name}}`).join(String(value)),
    t(key),
  );
  return Object.values(replacements).reduce(
    (message, value) => message.replace("%lld", String(value)),
    named,
  );
}

async function loadStrings() {
  try {
    const response = await fetch("/remote/strings.json");
    if (!response.ok) return;
    remoteStrings = await response.json();
    document.title = t("appTitle");
    applyStaticStrings();
  } catch {
    remoteStrings = {};
  }
}

function applyStaticStrings() {
  document.querySelectorAll("[data-i18n]").forEach((element) => {
    element.textContent = t(element.dataset.i18n);
  });
  document.querySelectorAll("[data-i18n-placeholder]").forEach((element) => {
    element.placeholder = t(element.dataset.i18nPlaceholder);
  });
  document.querySelectorAll("[data-i18n-aria-label]").forEach((element) => {
    element.setAttribute("aria-label", t(element.dataset.i18nAriaLabel));
  });
}

function setStatus(message, isError = false) {
  els.statusLine.textContent = message;
  els.statusLine.classList.toggle("error", isError);
  els.statusLine.classList.toggle("connected", message === t("status.connected") && !isError);
}

function setTerminalOutput(text, isEmpty = false) {
  els.terminalOutput.textContent = text;
  els.terminalOutput.classList.toggle("empty", isEmpty);
  if (!isEmpty) {
    els.terminalOutput.scrollTop = els.terminalOutput.scrollHeight;
  }
}

function authHeaders() {
  return { Authorization: `Bearer ${state.token}` };
}

function importTokenFromHash() {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const token = hash.get("token");
  if (!token) return;
  localStorage.setItem(storageKey, token);
  history.replaceState(null, "", window.location.pathname);
}

function loadToken() {
  importTokenFromHash();
  state.token = localStorage.getItem(storageKey) || "";
  els.tokenInput.value = state.token;
  updateVisibility();
}

function updateVisibility() {
  const hasToken = Boolean(state.token);
  els.tokenView.hidden = hasToken;
  els.remoteView.hidden = !hasToken;
  document.body.classList.toggle("has-token", hasToken);
}

async function rpc(method, params = {}) {
  const response = await fetch("/rpc", {
    method: "POST",
    headers: {
      ...authHeaders(),
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      method,
      params,
    }),
  });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    const status = payload.error?.code || response.status;
    throw new Error(format("error.requestFailed", { status }));
  }
  return payload.result;
}

async function fetchSnapshot() {
  setStatus(t("status.refreshing"));
  const response = await fetch("/snapshot", { headers: authHeaders() });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    if (response.status === 401) {
      throw new Error(t("error.tokenRejected"));
    }
    const status = payload.error?.code || response.status;
    throw new Error(format("error.snapshotFailed", { status }));
  }
  state.snapshot = payload.result;
  setStatus(t("status.connected"));
  renderTree();
  ensureSelection();
}

function allSurfaces() {
  const result = [];
  const windows = state.snapshot?.windows || [];
  for (const win of windows) {
    for (const workspace of win.workspaces || []) {
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) {
          result.push({ window: win, workspace, pane, surface });
        }
      }
    }
  }
  return result;
}

function ensureSelection() {
  const surfaces = allSurfaces();
  const refreshedSelection = state.selectedSurface
    ? surfaces.find((item) => item.surface.id === state.selectedSurface.surface.id && item.surface.type === "terminal")
    : null;
  if (refreshedSelection) {
    state.selectedSurface = refreshedSelection;
    renderTree();
    renderTerminalHeader();
    readSelectedTerminal().catch((error) => setStatus(error.message, true));
    return;
  }
  state.selectedSurface =
    surfaces.find((item) => item.surface.type === "terminal" && item.surface.focused) ||
    surfaces.find((item) => item.surface.type === "terminal") ||
    null;
  renderTree();
  renderTerminalHeader();
  if (state.selectedSurface) {
    readSelectedTerminal().catch((error) => setStatus(error.message, true));
  } else {
    setTerminalOutput(t("terminalEmptyOutput"), true);
  }
}

function renderTree() {
  const windows = state.snapshot?.windows || [];
  els.treeList.replaceChildren();
  if (!windows.length) {
    const empty = document.createElement("div");
    empty.className = "workspace-meta";
    empty.textContent = t("tree.noWindows");
    els.treeList.append(empty);
    return;
  }

  for (const win of windows) {
    for (const workspace of win.workspaces || []) {
      const card = document.createElement("section");
      card.className = "workspace";

      const title = document.createElement("div");
      title.className = "workspace-title";
      const name = document.createElement("span");
      name.textContent = workspace.title || t("tree.workspaceFallback");
      const marker = document.createElement("span");
      marker.textContent = workspace.selected ? t("tree.selected") : `#${workspace.index + 1}`;
      title.append(name, marker);

      const meta = document.createElement("div");
      meta.className = "workspace-meta";
      meta.textContent = format("tree.windowPanes", {
        window: win.index + 1,
        panes: workspace.panes?.length || 0,
      });

      const list = document.createElement("div");
      list.className = "surface-list";
      for (const pane of workspace.panes || []) {
        for (const surface of pane.surfaces || []) {
          const button = document.createElement("button");
          button.type = "button";
          button.className = "surface-button";
          button.classList.toggle("selected", state.selectedSurface?.surface.id === surface.id);
          button.classList.toggle("focused", Boolean(surface.focused));
          button.disabled = surface.type !== "terminal";
          button.addEventListener("click", () => {
            state.selectedSurface = { window: win, workspace, pane, surface };
            renderTree();
            renderTerminalHeader();
            readSelectedTerminal().catch((error) => setStatus(error.message, true));
          });
          const label = document.createElement("div");
          label.className = "surface-label";
          label.textContent = surface.title || surface.type || t("tree.surfaceFallback");
          const detail = document.createElement("div");
          detail.className = "surface-meta";
          const surfaceType = surface.type || t("tree.surfaceTypeFallback");
          detail.textContent = surface.focused ? `${surfaceType} - ${t("tree.focusedSurface")}` : surfaceType;
          button.append(label, detail);
          list.append(button);
        }
      }

      card.append(title, meta, list);
      els.treeList.append(card);
    }
  }
}

function renderTerminalHeader() {
  const selected = state.selectedSurface;
  if (!selected) {
    els.terminalTitle.textContent = t("noTerminalSelected");
    els.terminalMeta.textContent = t("selectTerminal");
    return;
  }
  els.terminalTitle.textContent = selected.surface.title || t("terminalFallback");
  els.terminalMeta.textContent = `${selected.workspace.title || t("tree.workspaceFallback")} - ${selected.surface.id.slice(0, 8)}`;
}

async function readSelectedTerminal() {
  const selected = state.selectedSurface;
  if (!selected) return;
  const result = await rpc("surface.read_text", {
    workspace_id: selected.workspace.id,
    surface_id: selected.surface.id,
    lines: 200,
  });
  const text = result.text || "";
  setTerminalOutput(text || t("terminalEmptyOutput"), !text);
}

async function sendText(text) {
  const selected = state.selectedSurface;
  if (!selected || !text) return;
  await rpc("surface.send_text", {
    workspace_id: selected.workspace.id,
    surface_id: selected.surface.id,
    text,
  });
  await readSelectedTerminal();
}

async function sendKey(key) {
  const selected = state.selectedSurface;
  if (!selected) return;
  await rpc("surface.send_key", {
    workspace_id: selected.workspace.id,
    surface_id: selected.surface.id,
    key,
  });
  await readSelectedTerminal();
}

function startPolling() {
  stopPolling();
  state.polling = window.setInterval(() => {
    if (!document.hidden && state.selectedSurface) {
      readSelectedTerminal().catch(() => {});
    }
  }, 3000);
}

function stopPolling() {
  if (state.polling) {
    window.clearInterval(state.polling);
    state.polling = null;
  }
}

els.tokenForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const token = els.tokenInput.value.trim();
  if (!token) return;
  localStorage.setItem(storageKey, token);
  state.token = token;
  updateVisibility();
  fetchSnapshot().then(startPolling).catch((error) => setStatus(error.message, true));
});

els.refreshButton.addEventListener("click", () => {
  fetchSnapshot().catch((error) => setStatus(error.message, true));
});

els.forgetButton.addEventListener("click", () => {
  localStorage.removeItem(storageKey);
  state.token = "";
  state.snapshot = null;
  state.selectedSurface = null;
  stopPolling();
  updateVisibility();
});

els.readButton.addEventListener("click", () => {
  readSelectedTerminal().catch((error) => setStatus(error.message, true));
});

els.sendForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = els.sendInput.value;
  els.sendInput.value = "";
  sendText(text).catch((error) => setStatus(error.message, true));
});

document.querySelectorAll("[data-key]").forEach((button) => {
  button.addEventListener("click", () => {
    sendKey(button.dataset.key).catch((error) => setStatus(error.message, true));
  });
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && state.token) {
    fetchSnapshot().catch((error) => setStatus(error.message, true));
  }
});

async function init() {
  await loadStrings();
  loadToken();
  if (state.token) {
    fetchSnapshot().then(startPolling).catch((error) => setStatus(error.message, true));
  }
}

init();
"""#
}
