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
    renderPane: () => renderPane
  });
  var symbol = (kind) => kind === "warn" || kind === "blocker" ? "exclamationmark.triangle" : kind === "receipt" ? "checkmark.circle" : "text.bubble";
  var time = (milliseconds) => new Date(milliseconds).toLocaleString();
  var key = (thread) => `${thread.channel}\x00${thread.thread}`;
  function appendPage(previous, incoming) {
    const rows = new Map(previous.map((thread) => [key(thread), thread]));
    for (const thread of incoming) {
      const before = rows.get(key(thread));
      const posts = new Map((before?.posts ?? []).map((post) => [post.id, post]));
      for (const post of thread.posts ?? []) {
        const prior = posts.get(post.id);
        const names = Object.fromEntries(Object.keys(post.sources ?? {}).map((name) => [name, null]));
        posts.set(post.id, { ...post, sources: { ...prior?.sources, ...names } });
      }
      rows.set(key(thread), { ...thread, ...posts.size ? { posts: [...posts.values()] } : {} });
    }
    return [...rows.values()];
  }
  function renderPane() {
    const [chats, setChats] = signal([]);
    const [recipient, setRecipient] = signal(null);
    const [threads, setThreads] = signal([]);
    const [selected, setSelected] = signal(null);
    const [busy, setBusy] = signal(false);
    const [problem, setProblem] = signal(null);
    const [nextCursor, setNextCursor] = signal(null);
    const [updated, setUpdated] = signal(null);
    let generation = 0;
    let alive = true;
    onCleanup(() => {
      alive = false;
      generation++;
    });
    async function read(chat, thread = null, cursor) {
      const request = ++generation;
      const previous = cursor ? threads() : [];
      setBusy(true);
      setProblem(null);
      if (!cursor) {
        setThreads([]);
        setSelected(null);
        setNextCursor(null);
        setUpdated(null);
      }
      try {
        if (!chat) {
          const result = await cmux.call("agent_chat.list");
          if (!alive || request !== generation)
            return;
          setChats(result.chats.filter((row) => !row.machine));
        } else {
          const params = { sessionId: chat.id, ...thread ? { channel: thread.channel, thread: thread.thread } : {}, ...cursor ? { cursor } : {} };
          const result = await cmux.call("forum.threads", params);
          if (!alive || request !== generation)
            return;
          const rows = appendPage(previous, result.threads);
          setThreads(rows);
          setSelected(thread ? rows.find((row) => key(row) === key(thread)) ?? null : null);
          setNextCursor(result.nextCursor ?? null);
          setUpdated(new Date().toLocaleTimeString());
        }
      } catch (e) {
        if (!alive || request !== generation)
          return;
        setChats([]);
        setThreads([]);
        setSelected(null);
        setNextCursor(null);
        setUpdated(null);
        setProblem(e.code === "scope.missing" ? "Allow Board to read work threads in Settings > Apps, then refresh." : "The forum is unavailable. Check access and the local service, then refresh.");
      } finally {
        if (alive && request === generation)
          setBusy(false);
      }
    }
    read(null);
    function choose(chat) {
      setRecipient(chat);
      read(chat);
    }
    function back() {
      if (selected()) {
        read(recipient());
        return;
      }
      setRecipient(null);
      read(null);
    }
    return VStack([
      HStack([
        Button("Back", back).disabled(() => !recipient() || busy()),
        Text(() => selected()?.thread ?? recipient()?.title ?? "Board").font("headline"),
        Button("Refresh", () => read(recipient(), selected())).disabled(busy)
      ]),
      Text(() => selected()?.channel ?? "Work threads").secondary(),
      () => busy() ? Text("Loading…").secondary() : null,
      () => problem() ? EmptyState({ title: "Board unavailable", message: problem(), symbol: "lock" }) : null,
      () => !busy() && !problem() && !recipient() && chats().length === 0 ? EmptyState({ title: "No local chats", message: "Open an agent chat on this machine to view its work threads.", symbol: "text.bubble" }) : null,
      ForEach({ items: () => recipient() ? [] : chats(), key: (chat) => chat.id }, (chat) => Row({ title: () => chat().title, subtitle: () => chat().id, symbol: "text.bubble" }).onTap(() => choose(chat()))),
      () => !busy() && !problem() && recipient() && threads().length === 0 ? EmptyState({ title: "No work threads yet", message: "Agent status, blockers and receipts will appear here.", symbol: "tray" }) : null,
      ForEach({ items: () => selected() ? [] : threads(), key }, (thread) => Row({ title: () => thread().thread, subtitle: () => `${thread().channel} · ${thread().latest.kind}`, symbol: () => symbol(thread().latest.kind) }).onTap(() => read(recipient(), thread()))),
      () => selected()?.lease ? Text(`Lease owner ${selected().lease.owner} · expires ${time(selected().lease.expires)}`).secondary() : null,
      ForEach({ items: () => selected() ? selected().posts ?? [] : [], key: (post) => post.id }, (post) => VStack([
        Row({ title: () => post().kind, subtitle: () => time(post().created), symbol: () => symbol(post().kind) }),
        Text(() => post().body),
        Text(() => {
          const names = Object.keys(post().sources ?? {});
          return `Sources ${names.length}/${post().sourceCount ?? names.length}: ${names.join(" · ")}`;
        }).secondary()
      ])),
      () => nextCursor() ? Button("Load more", () => read(recipient(), selected(), nextCursor())).disabled(busy) : null,
      Text(() => updated() ? `Updated ${updated()}` : "").secondary()
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
