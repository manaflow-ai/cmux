// sites.webmcp: tools a page declares for agents through WebMCP
// (navigator.modelContext, webmachinelearning.github.io/webmcp). WebKit has
// no native WebMCP yet, so this finds tools a page registers with a WebMCP
// implementation it ships itself (such as the MCP-B polyfill), or its
// document.modelContext. The page writes its tools' annotations, so
// readOnlyHint is advisory: every call is a confirmed draft, since it can
// change data or send it, unless the agent passes { trustReadOnlyHint: true }
// for that call to a tool that declares readOnlyHint.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;

  // Runs in the page world. arg: { op: "list", mark } or { op: "call",
  // name, input, descriptor, mark, url }. Each listed tool carries
  // `descriptor`, its name, title, description, input schema and
  // annotations as JSON with sorted keys; a call with a descriptor runs only
  // a tool whose descriptor is that one, checked right before it runs.
  // A list marks its document (`mark`, kept on the window, which a new
  // document does not have) and returns the mark and URL it found before
  // listing; a call runs only in the document with that mark at that URL,
  // checked first and again right before the tool runs.
  async function webmcp(arg) {
    const KEY = "__cmuxWebMCPDocument";
    const here = () => {
      try {
        return { mark: window[KEY], url: location.href };
      } catch (e) {
        return { mark: undefined, url: null };
      }
    };
    const moved = () => {
      const now = here();
      return now.mark !== arg.mark || now.url !== arg.url;
    };
    let listedAt = null;
    if (arg.op === "list") {
      if (typeof window[KEY] !== "string") {
        try {
          Object.defineProperty(window, KEY, { value: arg.mark, enumerable: false, writable: false, configurable: false });
        } catch (e) {}
      }
      listedAt = here();
    } else if (moved()) return { supported: true, moved: here().url };
    const mc = (navigator && navigator.modelContext) || document.modelContext || null;
    if (!mc) return { supported: false };
    const canon = (v) => (v === null || typeof v !== "object" ? JSON.stringify(v === undefined ? null : v) : Array.isArray(v) ? "[" + v.map(canon).join(",") + "]" : "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",") + "}");
    const norm = (t) => {
      const d = { name: t.name, title: t.title || null, description: t.description || "", inputSchema: typeof t.inputSchema === "string" ? JSON.parse(t.inputSchema) : t.inputSchema || null, annotations: t.annotations || {} };
      return { ...d, descriptor: canon(d) };
    };
    let tools = null;
    if (typeof mc.listTools === "function") tools = await mc.listTools();
    else if (typeof mc.codexGetTools === "function") tools = await mc.codexGetTools();
    else if (mc.tools) tools = mc.tools instanceof Map ? [...mc.tools.values()] : Array.isArray(mc.tools) ? mc.tools : Object.values(mc.tools);
    if (!tools) return { supported: true, listable: false };
    tools = (Array.isArray(tools) ? tools : tools.tools || []).map(norm);
    if (arg.op === "list") return { supported: true, listable: true, tools, mark: listedAt.mark, url: listedAt.url };
    const tool = tools.find((t) => t.name === arg.name);
    if (!tool) return { supported: true, listable: true, missing: true, tools: tools.map((t) => t.name) };
    if (typeof arg.descriptor === "string" && tool.descriptor !== arg.descriptor) return { supported: true, listable: true, changed: true };
    if (moved()) return { supported: true, moved: here().url };
    let result;
    if (typeof mc.executeTool === "function") result = await mc.executeTool(arg.name, arg.input);
    else if (typeof mc.callTool === "function") result = await mc.callTool({ name: arg.name, arguments: arg.input });
    else if (typeof mc.codexExecuteTool === "function") result = JSON.parse(await mc.codexExecuteTool({ name: arg.name }, JSON.stringify(arg.input)));
    else {
      const raw = (mc.tools instanceof Map ? mc.tools.get(arg.name) : (Array.isArray(mc.tools) ? mc.tools : Object.values(mc.tools || {})).find((t) => t.name === arg.name)) || null;
      if (!raw || typeof raw.execute !== "function") return { supported: true, listable: true, notCallable: true };
      result = await raw.execute(arg.input, { requestUserInteraction: async () => { throw new Error("user interaction is not available to agents"); } });
    }
    return { supported: true, result: JSON.parse(JSON.stringify(result === undefined ? null : result)) };
  }

  S.register(
    "webmcp",
    (t) => {
      const UNSUPPORTED = "webmcp: this page declares no WebMCP tools (no navigator.modelContext). WebKit has no built-in WebMCP; only pages that ship their own implementation expose tools.";
      // 64-bit FNV-1a of a descriptor, shown in a draft's preview. The
      // confirmation compares the whole descriptor, not this hash.
      const hash = t.hash;
      // A fresh mark for a document listed for the first time.
      const newMark = () => `${t.now().toString(36)}.${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`;
      // Tools with their descriptors (internal), and the document (mark)
      // and URL they were listed in (`at`).
      async function listRaw(page) {
        const r = await (page || t.currentPage()).evaluate(webmcp, { op: "list", mark: newMark() });
        if (!r.supported) return { supported: false, tools: [], note: UNSUPPORTED };
        if (!r.listable) return { supported: true, tools: [], note: "webmcp: the page has navigator.modelContext but its implementation offers no way to list tools" };
        return { supported: true, tools: r.tools, at: { mark: r.mark, url: r.url } };
      }
      async function list(page) {
        const { at, ...r } = await listRaw(page);
        return r.tools.length ? { ...r, tools: r.tools.map(({ descriptor, ...tool }) => tool) } : r;
      }
      async function run(page, name, input, descriptor, at) {
        const r = await page.evaluate(webmcp, { op: "call", name, input: input === undefined ? {} : input, descriptor, mark: at.mark, url: at.url });
        if (r.moved !== undefined) throw new S.SiteError("page_changed", `webmcp.call: the tab shows a new document or another URL (${r.moved || "unknown"}) since tool ${JSON.stringify(name)} was listed at ${at.url}; nothing was called`);
        if (!r.supported) throw new S.SiteError("unsupported", UNSUPPORTED);
        if (r.missing) throw new S.SiteError("not_found", `webmcp.call: the page has no tool ${JSON.stringify(name)}; tools: ${r.tools.join(", ")}`);
        if (r.changed) throw new S.SiteError("tool_changed", `webmcp.call: the page's tool ${JSON.stringify(name)} changed since the preview (its description, schema or annotations differ); nothing was called. Make a new draft and show it to the user again`);
        if (r.notCallable) throw new S.SiteError("unsupported", `webmcp.call: tool ${JSON.stringify(name)} cannot be called from outside the page`);
        return r.result;
      }
      return {
        // { supported, tools: [{ name, title, description, inputSchema, annotations }] } for the current tab or `page`.
        tools: (page) => list(page),
        // Calls a tool: returns a draft that call(draftId, { confirm: true })
        // runs. Options: { page, trustReadOnlyHint }. With trustReadOnlyHint:
        // true, a tool that declares readOnlyHint runs now; the agent takes
        // the page's word for that one call.
        async call(name, input, options = {}) {
          if (typeof name === "string" && /^draft-\d+-[0-9a-f]+$/.test(name)) return t.write("webmcp", "call", name, input);
          const page = options.page || t.currentPage();
          const { tools, at } = await listRaw(page);
          const tool = tools.find((x) => x.name === name);
          if (!tool) throw new S.SiteError("not_found", `webmcp.call: the page has no tool ${JSON.stringify(name)}; tools: ${tools.map((x) => x.name).join(", ") || "none"}`);
          // The tool runs only while it is the one just listed: its
          // readOnlyHint, or the draft's preview, describes that tool.
          const descriptor = tool.descriptor;
          // Both run only in the document and at the URL the tool was listed in.
          if (options.trustReadOnlyHint === true && tool.annotations && tool.annotations.readOnlyHint === true) return run(page, name, input, descriptor, at);
          const url = page.url();
          const shape = (x) => ({ tool: x.name, description: x.description, inputSchema: x.inputSchema, annotations: x.annotations, toolHash: hash(x.descriptor) });
          return t.write("webmcp", "call", { name, input }, undefined, () => ({
            category: "[9]/[14] a page tool that may change or send data",
            summary: `Call WebMCP tool "${name}" on ${url.split("?")[0]}`,
            // The principal is the page document that runs the tool.
            account: { page: url },
            target: shape(tool),
            content: { input: input === undefined ? {} : input },
            sent: ["input"],
            // The confirmed call sends the previewed (frozen) input to the
            // previewed tool: the tab's URL and the tool are read back, and
            // the call itself runs only in the document the tool was listed
            // in and only while its descriptor is the previewed one.
            commit: (c) =>
              c.write(
                async () => {
                  const now = await listRaw(page);
                  const found = (now.tools || []).find((x) => x.name === name);
                  return { page: page.url(), ...(found ? shape(found) : { tool: null }) };
                },
                () => run(page, c.intent.tool, c.intent.input, descriptor, at),
              ),
          }));
        },
      };
    },
    { summary: "List and call tools a page declares through WebMCP (calls are confirmed drafts)", writes: ["call"] },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
