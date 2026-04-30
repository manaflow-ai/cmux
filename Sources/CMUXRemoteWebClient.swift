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
        LocalizedEntry("terminalKeysLabel", key: "remoteAccess.web.terminal.keysLabel", defaultValue: "Terminal keys"),
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
    <section id="token-view" class="panel token-panel">
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
        <div>
          <h1 data-i18n="productName">\#(htmlText(strings["productName"]))</h1>
          <p id="status-line" data-i18n="status.disconnected">\#(htmlText(strings["status.disconnected"]))</p>
        </div>
        <div class="top-actions">
          <button id="refresh-button" type="button" data-i18n="refreshButton">\#(htmlText(strings["refreshButton"]))</button>
          <button id="forget-button" type="button" class="ghost" data-i18n="forgetButton">\#(htmlText(strings["forgetButton"]))</button>
        </div>
      </header>

      <section class="layout">
        <aside class="panel nav-panel">
          <div class="panel-title" data-i18n="sessionsTitle">\#(htmlText(strings["sessionsTitle"]))</div>
          <div id="tree-list" class="tree-list"></div>
        </aside>

        <section class="panel terminal-panel">
          <div class="terminal-head">
            <div>
              <div id="terminal-title" class="terminal-title" data-i18n="noTerminalSelected">\#(htmlText(strings["noTerminalSelected"]))</div>
              <div id="terminal-meta" class="terminal-meta" data-i18n="selectTerminal">\#(htmlText(strings["selectTerminal"]))</div>
            </div>
            <button id="read-button" type="button" class="ghost" data-i18n="readButton">\#(htmlText(strings["readButton"]))</button>
          </div>
          <pre id="terminal-output" class="terminal-output" aria-live="polite"></pre>
          <form id="send-form" class="send-form">
            <textarea id="send-input" rows="2" spellcheck="false" placeholder="\#(htmlAttribute(strings["inputPlaceholder"]))" data-i18n-placeholder="inputPlaceholder"></textarea>
            <button type="submit" data-i18n="sendButton">\#(htmlText(strings["sendButton"]))</button>
          </form>
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
  --bg: #121417;
  --panel: #1b1f24;
  --panel-2: #23282f;
  --text: #f4f0e8;
  --muted: #a8b0ba;
  --line: #333a43;
  --accent: #62d2a2;
  --danger: #ff7b72;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  min-height: 100%;
  background: var(--bg);
  color: var(--text);
  font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
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
  min-height: 42px;
  padding: 0 14px;
}

button:active {
  transform: translateY(1px);
}

button.primary,
button[type="submit"] {
  background: var(--accent);
  color: #07120d;
  border-color: transparent;
  font-weight: 700;
}

button.ghost {
  background: transparent;
}

input,
textarea {
  width: 100%;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #0f1114;
  color: var(--text);
  padding: 12px;
}

textarea {
  min-height: 70px;
  resize: vertical;
}

.shell {
  width: min(1180px, 100%);
  margin: 0 auto;
  padding: max(16px, env(safe-area-inset-top)) 14px max(18px, env(safe-area-inset-bottom));
}

.panel {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
}

.token-panel {
  margin: 12vh auto 0;
  max-width: 440px;
  padding: 18px;
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

h1,
p {
  margin: 0;
}

h1 {
  font-size: 22px;
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

.topbar,
.terminal-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.topbar {
  padding: 4px 2px 14px;
}

.top-actions {
  display: flex;
  gap: 8px;
}

.layout {
  display: grid;
  grid-template-columns: minmax(260px, 360px) 1fr;
  gap: 12px;
}

.nav-panel,
.terminal-panel {
  padding: 12px;
}

.panel-title {
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  margin-bottom: 8px;
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
  padding: 10px;
  background: #15191d;
}

.workspace-title {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  font-weight: 700;
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

.surface-button.selected {
  border-color: var(--accent);
}

.terminal-title {
  font-weight: 800;
}

.terminal-output {
  min-height: 46vh;
  max-height: 56vh;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
  margin: 12px 0;
  padding: 12px;
  border-radius: 8px;
  background: #080a0c;
  color: #e9e1d4;
  border: 1px solid #252b32;
  font: 12px/1.45 "SF Mono", Menlo, Consolas, monospace;
}

.send-form {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 8px;
}

.key-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin-top: 10px;
}

.error {
  color: var(--danger);
}

@media (max-width: 760px) {
  .shell {
    padding-left: 10px;
    padding-right: 10px;
  }

  .layout {
    grid-template-columns: 1fr;
  }

  .topbar {
    align-items: flex-start;
  }

  .top-actions {
    flex-direction: column;
  }

  .terminal-output {
    min-height: 38vh;
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
    els.terminalOutput.textContent = "";
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
          button.disabled = surface.type !== "terminal";
          button.addEventListener("click", () => {
            state.selectedSurface = { window: win, workspace, pane, surface };
            renderTree();
            renderTerminalHeader();
            readSelectedTerminal().catch((error) => setStatus(error.message, true));
          });
          const label = document.createElement("div");
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
  els.terminalOutput.textContent = result.text || "";
  els.terminalOutput.scrollTop = els.terminalOutput.scrollHeight;
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
