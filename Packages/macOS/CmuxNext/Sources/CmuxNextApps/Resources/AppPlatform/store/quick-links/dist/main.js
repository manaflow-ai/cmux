// Built by cmux app pack from src/main.ts. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var exports_main = {};
  __export(exports_main, {
    parseLinks: () => parseLinks,
    renderPane: () => renderPane,
    renderSection: () => renderSection
  });
  function parseLinks(text) {
    return text.split(`
`).map((line) => line.split("|").map((part) => part.trim())).filter((parts) => parts.length === 2 && /^https:\/\//.test(parts[1]) && parts[0].length > 0).map(([title, url]) => ({ title, url }));
  }
  var links = computed(() => parseLinks(String(cmux.app.settings().links ?? "")));
  function open(url) {
    cmux.actions.run("openBrowser", { url });
  }
  function rows() {
    return VStack({ spacing: 2 }, [
      ForEach({ items: links, key: (l) => l.url }, (l) => Row({ title: () => l().title, subtitle: () => l().url.replace("https://", ""), symbol: () => "link" }).help(() => l().url).onTap(() => open(l().url))),
      () => links().length === 0 ? EmptyState({ title: "No links yet", message: "Add links in Settings > Apps > Quick Links.", symbol: "link.badge.plus" }) : null
    ]);
  }
  function renderSection() {
    return rows();
  }
  function renderPane() {
    return rows();
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
