// End-to-end option controls: fetch provider options, start a session, set
// runtime options through the shared WS op, then verify a prompt still
// completes. Usage: bun test/options.e2e.ts [provider ...]
const PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);
const providersToTest = Bun.argv.slice(2).length
  ? Bun.argv.slice(2)
  : ["codex", "pi", "opencode"];
const TIMEOUT_MS = Number(process.env.E2E_TIMEOUT_MS ?? 180_000);

type OptionValue = string | boolean;
interface SessionOption {
  id: string;
  kind: "select" | "toggle";
  value: OptionValue;
  choices?: { value: string; label: string; disabled?: boolean }[];
  disabled?: boolean;
}

async function commandExists(name: string): Promise<boolean> {
  const proc = Bun.spawn(["zsh", "-lc", `command -v ${name}`], { stdout: "pipe", stderr: "pipe", env: { ...process.env } });
  const code = await proc.exited;
  return code === 0;
}

async function testClaudeCatalogCache(): Promise<string> {
  if (!(await commandExists("claude"))) return "claude catalog: SKIP (claude binary missing)";
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  const events: any[] = [];
  const errors: string[] = [];
  let opened = false;
  const waitFor = <T>(name: string, pred: () => T | false | null | undefined, timeout = TIMEOUT_MS): Promise<T> =>
    new Promise((resolve, reject) => {
      const started = Date.now();
      const tick = () => {
        const v = pred();
        if (v) return resolve(v);
        if (Date.now() - started > timeout) return reject(new Error(`claude catalog: timeout waiting for ${name}`));
        setTimeout(tick, 20);
      };
      tick();
    });
  const send = (obj: unknown) => ws.send(JSON.stringify(obj));
  ws.onopen = () => {
    opened = true;
    send({ op: "list-options", provider: "claude", cwd: `${import.meta.dir}/../scratch` });
  };
  ws.onmessage = (e) => {
    const msg = JSON.parse(String(e.data));
    events.push(msg);
    if (msg.kind === "error") errors.push(String(msg.message ?? ""));
  };
  try {
    await waitFor("open", () => opened);
    const first = await waitFor("first options-list", () => events.find((e) => e.kind === "options-list" && e.provider === "claude"));
    if (errors.length) throw new Error(`claude catalog: ${errors[0]}`);
    const model = (first.options as SessionOption[]).find((o) => o.id === "model");
    const choices = model?.choices ?? [];
    if (choices.length <= 1) throw new Error(`claude catalog: expected >1 model choice, got ${choices.length}`);
    assertClaudeCatalog(choices);
    const before = events.length;
    const started = performance.now();
    send({ op: "list-options", provider: "claude", cwd: `${import.meta.dir}/../scratch` });
    await waitFor("cached options-list", () => events.slice(before).find((e) => e.kind === "options-list" && e.provider === "claude"), 1_000);
    const elapsed = performance.now() - started;
    if (elapsed >= 250) throw new Error(`claude catalog: cached response took ${elapsed.toFixed(1)}ms`);
    return `claude catalog: OK (${choices.length} models, cached ${elapsed.toFixed(1)}ms)`;
  } finally {
    ws.close();
  }
}

function assertClaudeCatalog(choices: { value: string; label: string; disabled?: boolean }[]) {
  const values = choices.map((c) => c.value);
  const unique = new Set(values);
  if (unique.size !== values.length) throw new Error(`claude catalog: duplicate model values ${values.join(",")}`);
  const aliases = new Set(["opus", "sonnet", "haiku", "fable", "default"]);
  for (const value of values) {
    const base = value.replace(/\[1m\]$/i, "");
    if (aliases.has(base)) throw new Error(`claude catalog: bare alias leaked: ${value}`);
    if (/\[1m\]$/i.test(value) && values.includes(base)) throw new Error(`claude catalog: 1m duplicate leaked: ${value}`);
  }
  for (const gated of ["claude-fable-5", "claude-opus-4-8", "claude-opus-4-7"]) {
    if (!values.includes(gated)) throw new Error(`claude catalog: missing gated model ${gated}`);
  }
}

async function testProvider(provider: string): Promise<string> {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  const events: any[] = [];
  let sessionId = "";
  let options: SessionOption[] = [];
  let optionsEventCount = 0;
  const errors: string[] = [];
  let text = "";
  let doneCount = 0;
  let opened = false;

  const waitFor = <T>(name: string, pred: () => T | false | null | undefined): Promise<T> =>
    new Promise((resolve, reject) => {
      const started = Date.now();
      const tick = () => {
        const v = pred();
        if (v) return resolve(v);
        if (Date.now() - started > TIMEOUT_MS) return reject(new Error(`${provider}: timeout waiting for ${name}`));
        setTimeout(tick, 40);
      };
      tick();
    });

  const send = (obj: unknown) => ws.send(JSON.stringify(obj));
  ws.onopen = () => {
    opened = true;
    send({ op: "list-options", provider, cwd: `${import.meta.dir}/../scratch` });
  };
  ws.onmessage = (e) => {
    const msg = JSON.parse(String(e.data));
    events.push(msg);
    if (msg.kind === "session-created") sessionId = msg.session.id;
    if (msg.kind === "event" && msg.sessionId === sessionId) {
      const evt = msg.evt;
      if (evt.kind === "options") {
        options = evt.options;
        optionsEventCount++;
      }
      if (evt.kind === "error") errors.push(String(evt.message ?? ""));
      if (evt.kind === "delta" || evt.kind === "assistant") text += evt.text;
      if (evt.kind === "done") doneCount++;
    }
  };
  ws.onerror = () => {
    throw new Error(`${provider}: websocket error`);
  };

  try {
    await waitFor("open", () => opened);
    await waitFor("options-list", () => events.find((e) => e.kind === "options-list" && e.provider === provider));
    send({
      op: "start",
      provider,
      cwd: `${import.meta.dir}/../scratch`,
      autoApprove: true,
      prompt: "Reply with exactly the word READY and nothing else. Do not use tools.",
    });
    await waitFor("session-created", () => sessionId);
    await waitFor("initial options", () => options.length ? options : false);
    if (provider === "pi") assertPiThinkingIsEffort(options);
    await waitFor("first done", () => doneCount >= 1);

    await setOptionAndAssert(provider, sessionId, () => options, () => optionsEventCount, () => errors, send, waitFor, "model");
    if (provider === "codex") await setOptionAndAssert(provider, sessionId, () => options, () => optionsEventCount, () => errors, send, waitFor, "effort");
    if (provider === "pi") await setOptionAndAssert(provider, sessionId, () => options, () => optionsEventCount, () => errors, send, waitFor, "thinking");
    if (provider === "opencode") await setOptionAndAssert(provider, sessionId, () => options, () => optionsEventCount, () => errors, send, waitFor, "mode");

    text = "";
    send({ op: "send", sessionId, prompt: "Reply with exactly the word PONG and nothing else. Do not use tools." });
    await waitFor("second done", () => doneCount >= 2);
    if (!text.toUpperCase().includes("PONG")) throw new Error(`${provider}: no PONG after option changes; text=${JSON.stringify(text.slice(0, 200))}`);
    return `${provider}: OK`;
  } finally {
    ws.close();
  }
}

async function setOptionAndAssert(
  provider: string,
  sessionId: string,
  current: () => SessionOption[],
  optionEvents: () => number,
  currentErrors: () => string[],
  send: (obj: unknown) => void,
  waitFor: <T>(name: string, pred: () => T | false | null | undefined) => Promise<T>,
  id: string,
) {
  const opt = current().find((o) => o.id === id && !o.disabled);
  if (!opt) throw new Error(`${provider}: missing option ${id}`);
  const value = id === "model" ? String(opt.value) : nextValue(opt);
  const beforeEvents = optionEvents();
  const beforeErrors = currentErrors().length;
  let failure = "";
  send({ op: "set-option", sessionId, id, value });
  await waitFor(`option ${id}=${String(value)}`, () => {
    const err = currentErrors()[beforeErrors];
    if (err) {
      failure = err;
      return true;
    }
    const next = current().find((o) => o.id === id);
    return optionEvents() > beforeEvents && next?.value === value ? true : false;
  }).catch(async () => {
    throw new Error(`${provider}: option ${id} did not emit updated options for ${String(value)}`);
  });
  if (failure) throw new Error(`${provider}: option ${id} failed: ${failure}`);
}

function nextValue(opt: SessionOption): OptionValue {
  if (opt.kind === "toggle") return !opt.value;
  const choices = opt.choices ?? [];
  if (!choices.length) return String(opt.value);
  const i = choices.findIndex((c) => c.value === opt.value);
  return choices[(i + 1 + choices.length) % choices.length]?.value ?? choices[0].value;
}

function assertPiThinkingIsEffort(options: SessionOption[]) {
  const thinking = options.find((o) => o.id === "thinking");
  if (!thinking) throw new Error("pi: missing thinking option");
  if (String(thinking.value).toLowerCase() === "off") throw new Error("pi: thinking reported off");
  if ((thinking.choices ?? []).some((c) => c.value.toLowerCase() === "off")) throw new Error("pi: thinking choices include off");
}

let failed = 0;
try {
  console.log(await testClaudeCatalogCache());
} catch (err) {
  failed++;
  console.error(String(err));
}
for (const p of providersToTest) {
  try {
    console.log(await testProvider(p));
  } catch (err) {
    failed++;
    console.error(String(err));
  }
}
process.exit(failed ? 1 : 0);
