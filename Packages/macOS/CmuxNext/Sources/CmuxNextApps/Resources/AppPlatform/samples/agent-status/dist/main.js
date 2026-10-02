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
    renderStatus: () => renderStatus
  });
  async function focusTerminal(terminal) {
    const t = await cmux.terminal.get({ terminal });
    if (t.tab_id)
      await cmux.tab.focus({ tab: t.tab_id });
  }
  function renderStatus() {
    const agents = cmux.live("agent.list", {});
    const working = computed(() => (agents() ?? []).filter((a) => a.state === "working").length);
    const waiting = computed(() => (agents() ?? []).filter((a) => a.state === "blocked").length);
    const summary = computed(() => {
      const parts = [];
      if (working())
        parts.push(`${working()} working`);
      if (waiting())
        parts.push(`${waiting()} waiting`);
      return parts.join(" · ") || "No agents";
    });
    const menu = () => (agents() ?? []).filter((a) => a.state === "working" || a.state === "blocked").map((a) => Button(`${a.state === "blocked" ? "Waiting" : "Working"}: ${String(a.extra?.name ?? a.source)}`, () => focusTerminal(a.terminal_id)));
    return HStack({ spacing: 4 }, [
      Icon(() => waiting() ? "exclamationmark.bubble" : "sparkles").color(() => waiting() ? "warning" : "secondary"),
      Text(summary).font("caption").monospaced(),
      () => waiting() ? Badge(waiting, "warning") : null
    ]).paddingHorizontal(6).cornerRadius(6).hoverBackground("hover").contextMenu(menu);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
