import type { Adapter, CommandEntry, OptionChoice, OptionValue, SessionCtx, SessionOption } from "../types";
import { readLines, tryParse, truncate } from "./lines";
import { prettifyModelLabel } from "./model-label";
import { agentModelCatalog, selectEnabledModel } from "../catalog";
import { inheritedClaudeLaunchStateKeys } from "./claude-environment-policy.generated";

const PERMISSION_CHOICES: OptionChoice[] = [
  { value: "default", label: "Default" },
  { value: "acceptEdits", label: "Accept edits" },
  { value: "plan", label: "Plan" },
  { value: "bypassPermissions", label: "Bypass" },
  { value: "dontAsk", label: "Don't ask" },
  { value: "auto", label: "Auto" },
];
const THINKING_CHOICES: OptionChoice[] = [
  { value: "0", label: "Thinking off" },
  { value: "4096", label: "4k thinking" },
  { value: "16384", label: "16k thinking" },
  { value: "32768", label: "32k thinking" },
];
const EFFORT_CHOICES: OptionChoice[] = ["low", "medium", "high", "xhigh", "max"]
  .map((value) => ({ value, label: value }));
const CONTEXT_CHOICES: OptionChoice[] = [
  { value: "200k", label: "200k" },
  { value: "1m", label: "1M" },
];
const DEFAULT_CLAUDE_MODEL = "claude-sonnet-5";
const MINIMUM_CLAUDE_FABLE_5_VERSION = "2.1.169";
const MINIMUM_CLAUDE_OPUS_4_8_VERSION = "2.1.154";
const MINIMUM_CLAUDE_OPUS_4_7_VERSION = "2.1.111";
const VERSION_TTL_MS = 10 * 60_000;
const BUILT_IN_MODELS: Array<{ slug: string; label: string; minVersion?: string; context?: boolean; fast?: boolean }> = [
  { slug: "claude-fable-5", label: "Claude Fable 5", minVersion: MINIMUM_CLAUDE_FABLE_5_VERSION, context: true },
  { slug: "claude-opus-4-8", label: "Claude Opus 4.8", minVersion: MINIMUM_CLAUDE_OPUS_4_8_VERSION, fast: true },
  { slug: "claude-opus-4-7", label: "Claude Opus 4.7", minVersion: MINIMUM_CLAUDE_OPUS_4_7_VERSION, fast: true },
  { slug: "claude-opus-4-6", label: "Claude Opus 4.6", context: true, fast: true },
  { slug: "claude-opus-4-5", label: "Claude Opus 4.5", fast: true },
  { slug: "claude-sonnet-5", label: "Claude Sonnet 5", context: true },
  { slug: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", context: true },
  { slug: "claude-haiku-4-5", label: "Claude Haiku 4.5" },
];

export function claudeIndependentLaunchEnvironment(
  environment: Record<string, string | undefined> = process.env,
): Record<string, string | undefined> {
  const launchEnvironment = { ...environment };
  for (const key of inheritedClaudeLaunchStateKeys) delete launchEnvironment[key];
  return launchEnvironment;
}

function curatedClaudeModels(): Array<{ slug: string; label: string; description?: string; minVersion?: string; context?: boolean; fast?: boolean; deprecated?: boolean }> {
  const remote = agentModelCatalog.provider("claude");
  if (remote) return remote.models.map((model) => ({
    slug: model.id,
    label: model.label,
    description: model.description,
    minVersion: model.minVersion,
    context: model.supportsOneMillion === true,
    fast: model.fast,
    deprecated: model.deprecated === true,
  }));
  return agentModelCatalog.hasPayload ? [] : BUILT_IN_MODELS;
}

function defaultClaudeModel(): string {
  return agentModelCatalog.provider("claude")?.defaultModel ?? DEFAULT_CLAUDE_MODEL;
}
let claudeVersionCache: { value: string | null; fetchedAt: number; promise?: Promise<string | null> } | null = null;
interface ClaudeModelMeta {
  efforts: OptionChoice[];
  supportsFastMode: boolean;
  context?: { base: string; extended: string };
}

interface ClaudeState {
  proc?: Bun.Subprocess<"pipe", "pipe", "pipe">;
  nextRequest: number;
  pending: Map<string, { resolve: (v: any) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>;
  model: string;
  modelChoices: OptionChoice[];
  modelMeta: Map<string, ClaudeModelMeta>;
  permissionMode: string;
  thinking: string;
  effort: string;
  fastMode: boolean;
  context: string;
  initialApplied: boolean;
  commands: CommandEntry[];
  activeTurns: number;
  activeGenerations: Array<number | undefined>;
}

export const claudeAdapter: Adapter = {
  capabilities: {
    triggers: ["/"],
    options: [
      { id: "model", label: "Model", kind: "select", value: DEFAULT_CLAUDE_MODEL, choices: [{ value: DEFAULT_CLAUDE_MODEL, label: "Claude Sonnet 5" }], disabled: true, description: "Loads at start" },
      { id: "permissionMode", label: "Mode", kind: "select", value: "acceptEdits", choices: PERMISSION_CHOICES },
      { id: "thinking", label: "Thinking", kind: "select", value: "0", role: "thinking-budget", choices: THINKING_CHOICES },
      { id: "effort", label: "Effort", kind: "select", value: "medium", role: "effort", choices: EFFORT_CHOICES },
      { id: "fastMode", label: "Fast", kind: "toggle", value: false },
    ],
  },
  async send(sess, prompt, generation?: number) {
    const proc = ensureProc(sess);
    await applyInitialOptions(sess);
    const msg = {
      type: "user",
      message: { role: "user", content: [{ type: "text", text: prompt }] },
    };
    beginTurn(sess, generation);
    proc.stdin.write(JSON.stringify(msg) + "\n");
    proc.stdin.flush();
    sess.setStatus("running");
  },
  stop(sess) {
    const proc = state(sess).proc;
    if (!proc || proc.exitCode !== null || proc.killed) return;
    control(sess, "interrupt").catch((err) => {
      sess.emit({ kind: "error", message: truncate(String(err), 200) });
    });
  },
  dispose(sess) {
    const st = state(sess);
    const proc = st.proc;
    st.proc = undefined;
    for (const p of st.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("claude process disposed"));
    }
    st.pending.clear();
    proc?.kill();
  },
  async setOption(sess, id, value) {
    await setClaudeOption(sess, id, value);
  },
  async refreshOptions(sess) {
    await refreshClaudeOptions(sess);
  },
  async listOptions(cwd) {
    const choices = await fetchClaudeModels(cwd);
    const st = {
      model: enabledClaudeDefault(choices.choices),
      modelChoices: choices.choices,
      modelMeta: choices.meta,
      permissionMode: "acceptEdits",
      thinking: "0",
      effort: "medium",
      fastMode: false,
      context: "200k",
    };
    normalizeEffort(st);
    return buildOptions(st);
  },
  async forkSession(source, target) {
    const providerSessionId = source.internal.providerSessionId as string | undefined;
    if (!providerSessionId) throw new Error("claude session id is not available yet");
    target.internal.claudeFork = { providerSessionId };
  },
};

function state(sess: SessionCtx): ClaudeState {
  let st = sess.internal.claude as ClaudeState | undefined;
  if (!st) {
    st = {
      nextRequest: 1,
      pending: new Map(),
      model: normalizeStartModel(stringOption(sess, "model", seededClaudeDefault(sess))),
      modelChoices: [{ value: seededClaudeDefault(sess), label: seededClaudeDefault(sess) }],
      modelMeta: new Map([[seededClaudeDefault(sess), { efforts: EFFORT_CHOICES, supportsFastMode: false }]]),
      permissionMode: stringOption(sess, "permissionMode", sess.autoApprove ? "acceptEdits" : "default"),
      thinking: stringOption(sess, "thinking", "0"),
      effort: stringOption(sess, "effort", "medium"),
      fastMode: booleanOption(sess, "fastMode", false),
      context: stringOption(sess, "context", "200k"),
      initialApplied: false,
      commands: [],
      activeTurns: 0,
      activeGenerations: [],
    };
    sess.internal.claude = st;
  }
  return st;
}

function stringOption(sess: SessionCtx, id: string, fallback: string): string {
  const v = sess.startOptions[id];
  return typeof v === "string" ? v : fallback;
}

function normalizeStartModel(value: string): string {
  if (value === "default") return defaultClaudeModel();
  const base = stripOneMillion(value).base;
  return isRemoteClaudeId(base) ? base : aliasClaudeModel(base);
}

function seededClaudeDefault(sess: SessionCtx): string {
  const seeded = sess.seedOptions?.find((option) => option.id === "model");
  return typeof seeded?.value === "string" && seeded.value ? seeded.value : defaultClaudeModel();
}

function isRemoteClaudeId(value: string): boolean {
  return agentModelCatalog.provider("claude")?.models.some((model) => model.id === value) === true;
}

function booleanOption(sess: SessionCtx, id: string, fallback: boolean): boolean {
  const v = sess.startOptions[id];
  return typeof v === "boolean" ? v : fallback;
}

function ensureProc(sess: SessionCtx): Bun.Subprocess<"pipe", "pipe", "pipe"> {
  const st = state(sess);
  if (st.proc && st.proc.exitCode === null && !st.proc.killed) return st.proc;

  // A replacement process starts from spawn-flag state only; re-run the
  // control-message option pass so runtime changes (thinking, effort, fast
  // mode) survive a respawn.
  if (sess.internal.claudeSpawnedOnce) st.initialApplied = false;
  sess.internal.claudeSpawnedOnce = true;

  const args = [
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
  ];
  const apiModel = resolveClaudeModelId(st);
  if (apiModel) args.push("--model", apiModel);
  const fork = sess.internal.claudeFork as { providerSessionId?: string } | undefined;
  if (fork?.providerSessionId) args.push("--resume", fork.providerSessionId, "--fork-session");
  if (st.permissionMode !== "default") args.push("--permission-mode", st.permissionMode);
  if (sess.autoApprove) args.push("--allowedTools", "Bash Read Edit Write Glob Grep WebFetch WebSearch");
  if (typeof sess.startOptions.effort === "string") args.push("--effort", st.effort);

  const proc = Bun.spawn(["claude", ...args], {
    cwd: sess.cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: claudeIndependentLaunchEnvironment(),
  });
  st.proc = proc;

  readLines(proc.stdout, (line) => handleLine(sess, line), () => {
    if (st.proc === proc) {
      handleProcessClose(sess, st, "claude process exited");
    }
  });
  readLines(proc.stderr, (line) => {
    sess.internal.lastStderr = line;
  });
  proc.exited.then((code) => {
    if (code !== 0 && st.proc === proc) {
      const err = sess.internal.lastStderr as string | undefined;
      handleProcessClose(sess, st, `claude exited (${code})`, `claude exited (${code})${err ? ": " + truncate(err) : ""}`);
    }
  });
  return proc;
}

function beginTurn(sess: SessionCtx, generation?: number) {
  const st = state(sess);
  st.activeTurns += 1;
  st.activeGenerations.push(generation);
}

function finishTurn(sess: SessionCtx, stats?: string): number {
  const st = state(sess);
  if (st.activeTurns <= 0) return 0;
  st.activeTurns -= 1;
  const generation = st.activeGenerations.shift();
  sess.emit({ kind: "done", stats, generation } as any);
  return st.activeTurns;
}

function handleProcessClose(sess: SessionCtx, st: ClaudeState, pendingMessage: string, turnError = "claude process exited mid-turn") {
  const wasActive = st.activeTurns > 0;
  const generations = st.activeGenerations.splice(0);
  while (generations.length < st.activeTurns) generations.push(undefined);
  st.activeTurns = 0;
  st.activeGenerations = [];
  st.proc = undefined;
  rejectPending(st, pendingMessage);
  if (wasActive) {
    for (const generation of generations) {
      sess.emit({ kind: "error", message: turnError });
      sess.emit({ kind: "done", generation } as any);
    }
  }
  sess.setStatus("idle");
}

export function claudeHandleLineForTest(sess: SessionCtx, line: string) {
  handleLine(sess, line);
}

export function claudeProcessCloseForTest(sess: SessionCtx, turnError?: string) {
  handleProcessClose(sess, state(sess), "claude process exited", turnError);
}

function rejectPending(st: ClaudeState, message: string) {
  for (const p of st.pending.values()) {
    clearTimeout(p.timer);
    p.reject(new Error(message));
  }
  st.pending.clear();
}

function control(sess: SessionCtx, subtype: string, request: Record<string, unknown> = {}): Promise<any> {
  const st = state(sess);
  const proc = ensureProc(sess);
  const request_id = `cmux-${st.nextRequest++}`;
  const payload = { type: "control_request", request_id, request: { subtype, ...request } };
  const promise = new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => {
      st.pending.delete(request_id);
      reject(new Error(`claude ${subtype} timed out`));
    }, 12_000);
    st.pending.set(request_id, { resolve, reject, timer });
  });
  proc.stdin.write(JSON.stringify(payload) + "\n");
  proc.stdin.flush();
  return promise.then((response) => {
    if (response?.subtype && response.subtype !== "success") {
      throw new Error(response.error ?? response.message ?? `${subtype} failed`);
    }
    return response?.response;
  });
}

async function applyInitialOptions(sess: SessionCtx) {
  const st = state(sess);
  if (st.initialApplied) return;
  st.initialApplied = true;
  // Apply when the caller pinned a start option OR the tracked value has
  // drifted from the spawn default (a runtime setOption before a respawn).
  if (typeof sess.startOptions.thinking === "string" || st.thinking !== "0") {
    await control(sess, "set_max_thinking_tokens", { max_thinking_tokens: Number(st.thinking) || 0 });
  }
  if (typeof sess.startOptions.effort === "string" || st.effort !== "medium") {
    await control(sess, "apply_flag_settings", { settings: { effortLevel: st.effort } });
  }
  if (typeof sess.startOptions.fastMode === "boolean" || st.fastMode) {
    await control(sess, "apply_flag_settings", { settings: { fastMode: st.fastMode } });
  }
  emitOptions(sess);
}

async function setClaudeOption(sess: SessionCtx, id: string, value: OptionValue) {
  const st = state(sess);
  switch (id) {
    case "model": {
      if (typeof value !== "string") throw new Error("model must be a string");
      st.model = value;
      normalizeContext(st);
      const model = resolveClaudeModelId(st);
      await control(sess, "set_model", { model });
      const changed = normalizeEffort(st);
      if (changed.effort) await control(sess, "apply_flag_settings", { settings: { effortLevel: st.effort } });
      if (changed.fastMode) await control(sess, "apply_flag_settings", { settings: { fastMode: st.fastMode } });
      break;
    }
    case "context": {
      if (typeof value !== "string") throw new Error("context must be a string");
      st.context = value;
      normalizeContext(st);
      const model = resolveClaudeModelId(st);
      await control(sess, "set_model", { model });
      break;
    }
    case "permissionMode": {
      if (typeof value !== "string") throw new Error("permissionMode must be a string");
      const res = await control(sess, "set_permission_mode", { mode: value });
      st.permissionMode = String(res?.mode ?? value);
      break;
    }
    case "thinking": {
      if (typeof value !== "string") throw new Error("thinking must be a string");
      await control(sess, "set_max_thinking_tokens", { max_thinking_tokens: Number(value) || 0 });
      st.thinking = value;
      break;
    }
    case "effort": {
      if (typeof value !== "string") throw new Error("effort must be a string");
      await control(sess, "apply_flag_settings", { settings: { effortLevel: value } });
      st.effort = value;
      break;
    }
    case "fastMode": {
      if (typeof value !== "boolean") throw new Error("fastMode must be boolean");
      await control(sess, "apply_flag_settings", { settings: { fastMode: value } });
      st.fastMode = value;
      break;
    }
    default:
      throw new Error(`unsupported claude option: ${id}`);
  }
  emitOptions(sess);
}

async function refreshClaudeOptions(sess: SessionCtx) {
  const st = state(sess);
  if (seedModelChoices(sess, st)) emitOptions(sess);
  const res = await control(sess, "list_models");
  const version = await fetchClaudeVersion();
  const catalog = normalizeModelCatalog(res?.models, version);
  st.modelChoices = catalog.choices;
  st.modelMeta = catalog.meta;
  const selected = st.modelChoices.find((choice) => choice.value === st.model);
  if (!selected || selected.disabled) st.model = enabledClaudeDefault(st.modelChoices);
  normalizeContext(st);
  normalizeEffort(st);
  emitOptions(sess);
  if (st.commands.length) sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
}

function seedModelChoices(sess: SessionCtx, st: ClaudeState): boolean {
  const seeded = sess.seedOptions?.find((o) => o.id === "model")?.choices;
  if (!seeded || seeded.length <= 1 || st.modelChoices.length > 1) return false;
  st.modelChoices = seeded;
  return true;
}

function emitOptions(sess: SessionCtx) {
  sess.emit({ kind: "options", options: buildOptions(state(sess)), actions: { fork: true } });
}

function buildOptions(st: Pick<ClaudeState, "model" | "modelChoices" | "modelMeta" | "permissionMode" | "thinking" | "effort" | "fastMode" | "context">): SessionOption[] {
  const meta = modelMeta(st);
  const opts: SessionOption[] = [
    { id: "model", label: "Model", kind: "select", value: st.model, choices: st.modelChoices.length ? st.modelChoices : [{ value: defaultClaudeModel(), label: defaultClaudeModel() }] },
    { id: "permissionMode", label: "Mode", kind: "select", value: st.permissionMode, choices: PERMISSION_CHOICES },
    { id: "thinking", label: "Thinking", kind: "select", value: st.thinking, role: "thinking-budget", choices: THINKING_CHOICES },
    { id: "effort", label: "Effort", kind: "select", value: st.effort, role: "effort", choices: meta.efforts },
  ];
  if (meta.context) opts.push({ id: "context", label: "Context", kind: "select", value: st.context, role: "context", choices: CONTEXT_CHOICES });
  if (meta.supportsFastMode) opts.push({ id: "fastMode", label: "Fast", kind: "toggle", value: st.fastMode });
  return opts;
}

function modelMeta(st: Pick<ClaudeState, "model" | "modelMeta">): ClaudeModelMeta {
  return st.modelMeta.get(st.model) ?? st.modelMeta.get(defaultClaudeModel()) ?? { efforts: EFFORT_CHOICES, supportsFastMode: false };
}

function normalizeEffort(st: Pick<ClaudeState, "model" | "modelMeta" | "effort" | "fastMode">): { effort: boolean; fastMode: boolean } {
  const meta = modelMeta(st);
  const beforeEffort = st.effort;
  const beforeFast = st.fastMode;
  if (!meta.efforts.some((c) => c.value === st.effort)) st.effort = meta.efforts[0]?.value ?? "medium";
  if (!meta.supportsFastMode) st.fastMode = false;
  return { effort: st.effort !== beforeEffort, fastMode: st.fastMode !== beforeFast };
}

function normalizeContext(st: Pick<ClaudeState, "model" | "modelMeta" | "context">): boolean {
  const beforeModel = st.model;
  const beforeContext = st.context;
  const parsed = stripOneMillion(st.model);
  if (parsed.suffix) {
    const base = aliasClaudeModel(parsed.base);
    if (st.modelMeta.get(base)?.context) {
      st.model = base;
      st.context = "1m";
    }
  }
  if (!modelMeta(st).context) st.context = "200k";
  if (!CONTEXT_CHOICES.some((c) => c.value === st.context)) st.context = "200k";
  return st.model !== beforeModel || st.context !== beforeContext;
}

function resolveClaudeModelId(st: Pick<ClaudeState, "model" | "modelMeta" | "context">): string {
  const meta = modelMeta(st);
  if (meta.context && st.context === "1m") return meta.context.extended;
  return st.model;
}

function normalizeModelCatalog(models: any, version: string | null): { choices: OptionChoice[]; meta: Map<string, ClaudeModelMeta> } {
  const meta = new Map<string, ClaudeModelMeta>();
  const choices: OptionChoice[] = [];
  const covered = new Set<string>();
  const rawModels = Array.isArray(models) ? models : [];
  const raw = rawModels.map((m) => {
    const value = String(m.value ?? m.model ?? m.id ?? "");
    if (!value || bareClaudeAlias(value) === "default") return null;
    const parsed = stripOneMillion(value);
    const base = aliasClaudeModel(parsed.base);
    const normalizedValue = parsed.suffix ? `${base}${parsed.suffix}` : base;
    return {
      rawValue: value,
      value: normalizedValue,
      base,
      suffix: parsed.suffix,
      label: prettifyModelLabel(String(m.displayName ?? m.name ?? m.value ?? "Model")),
      description: m.description ? String(m.description) : undefined,
      meta: {
        supportsFastMode: m.supportsFastMode === true,
        efforts: Array.isArray(m.supportedEffortLevels) && m.supportedEffortLevels.length
          ? m.supportedEffortLevels.map((effort: unknown) => ({ value: String(effort), label: String(effort) }))
          : EFFORT_CHOICES,
      },
    };
  }).filter(Boolean) as Array<{ rawValue: string; value: string; base: string; suffix: string; label: string; description?: string; meta: { supportsFastMode: boolean; efforts: OptionChoice[] } }>;
  const rawByBase = new Map<string, typeof raw[number]>();
  const extendedByBase = new Map<string, typeof raw[number]>();
  for (const m of raw) if (!m.suffix && !rawByBase.has(m.base)) rawByBase.set(m.base, m);
  for (const m of raw) if (m.suffix && !extendedByBase.has(m.base)) extendedByBase.set(m.base, m);
  for (const model of curatedClaudeModels()) {
    const disabledReason = model.minVersion && version && !versionAtLeast(version, model.minVersion)
      ? claudeUpgradeMessage(model.slug, model.label, model.minVersion, version)
      : model.deprecated ? `${model.label} is deprecated.` : undefined;
    choices.push({ value: model.slug, label: model.label, description: model.description, disabled: Boolean(disabledReason), disabledReason });
    covered.add(model.slug);
    covered.add(aliasClaudeModel(stripOneMillion(model.slug).base));
    const extended = extendedByBase.get(model.slug)?.value ?? `${model.slug}[1m]`;
    const context = model.context || extendedByBase.has(model.slug)
      ? { base: model.slug, extended }
      : undefined;
    const binary = rawByBase.get(model.slug);
    meta.set(model.slug, { efforts: binary?.meta.efforts ?? EFFORT_CHOICES, supportsFastMode: model.fast ?? binary?.meta.supportsFastMode ?? false, ...(context ? { context } : {}) });
  }
  for (const m of raw) {
    if (covered.has(m.base)) {
      const existing = meta.get(m.base);
      if (existing && m.suffix && !existing.context) existing.context = { base: m.base, extended: m.value };
      continue;
    }
    if (m.suffix && rawByBase.has(m.base)) continue;
    if (extendedByBase.has(m.base)) {
      const extended = extendedByBase.get(m.base)!;
      meta.set(m.base, { efforts: m.meta.efforts, supportsFastMode: m.meta.supportsFastMode, context: { base: m.base, extended: extended.value } });
      choices.push({ value: m.base, label: m.label, description: m.description });
    } else {
      meta.set(m.base, { efforts: m.meta.efforts, supportsFastMode: m.meta.supportsFastMode });
      choices.push({ value: m.base, label: m.label, description: m.description });
    }
    covered.add(m.base);
  }
  return { choices: dedupeChoices(choices), meta };
}

async function fetchClaudeVersion(): Promise<string | null> {
  const now = Date.now();
  if (claudeVersionCache?.promise) return claudeVersionCache.promise;
  if (claudeVersionCache && (claudeVersionCache.value || now - claudeVersionCache.fetchedAt < VERSION_TTL_MS)) return claudeVersionCache.value;
  const promise = (async () => {
      try {
        const proc = Bun.spawn(["claude", "--version"], { stdout: "pipe", stderr: "pipe", env: { ...process.env } });
        const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
        if (code !== 0) return null;
        const text = `${out}\n${err}`;
        return text.match(/\d+\.\d+\.\d+/)?.[0] ?? null;
      } catch {
        return null;
      }
    })();
  claudeVersionCache = { value: null, fetchedAt: now, promise };
  const value = await promise;
  claudeVersionCache = { value, fetchedAt: Date.now() };
  return value;
}

function stripOneMillion(value: string): { base: string; suffix: string } {
  const match = value.match(/\[1m\]$/i);
  return match ? { base: value.slice(0, -match[0].length), suffix: match[0] } : { base: value, suffix: "" };
}

function bareClaudeAlias(value: string): string {
  return stripOneMillion(value).base.toLowerCase();
}

function aliasClaudeModel(value: string): string {
  const lower = value.toLowerCase();
  if (lower === "opus") return "claude-opus-4-8";
  if (lower === "fable") return "claude-fable-5";
  if (lower === "sonnet") return "claude-sonnet-5";
  if (lower === "haiku") return "claude-haiku-4-5";
  return value;
}

function enabledClaudeDefault(choices: OptionChoice[]): string {
  return selectEnabledModel(defaultClaudeModel(), choices.map((choice) => ({ id: choice.value, disabled: choice.disabled })));
}

function claudeUpgradeMessage(slug: string, label: string, min: string, version: string | null): string {
  const versionLabel = version ? `v${version}` : "the installed version";
  return `Claude Code ${versionLabel} is too old for ${label}. Upgrade to v${min} or newer to access it.`;
}

function dedupeChoices(choices: OptionChoice[]): OptionChoice[] {
  const seen = new Set<string>();
  const out: OptionChoice[] = [];
  for (const choice of choices) {
    const base = stripOneMillion(choice.value).base;
    const key = isRemoteClaudeId(base) ? base : aliasClaudeModel(base);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(choice);
  }
  return out.sort((a, b) => {
    const curated = curatedClaudeModels();
    const ai = curated.findIndex((m) => m.slug === a.value);
    const bi = curated.findIndex((m) => m.slug === b.value);
    if (ai >= 0 && bi >= 0) return ai - bi;
    if (ai >= 0) return -1;
    if (bi >= 0) return 1;
    return a.label.localeCompare(b.label);
  });
}

function versionAtLeast(version: string | null, min: string): boolean {
  if (!version) return true;
  const a = version.split(".").map((p) => Number(p) || 0);
  const b = min.split(".").map((p) => Number(p) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0);
    if (d !== 0) return d > 0;
  }
  return true;
}

async function fetchClaudeModels(cwd: string): Promise<{ choices: OptionChoice[]; meta: Map<string, ClaudeModelMeta> }> {
  const version = await fetchClaudeVersion();
  const proc = Bun.spawn([
    "claude",
    "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--include-partial-messages",
    "--verbose",
  ], {
    cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: claudeIndependentLaunchEnvironment(),
  });
  try {
    return await new Promise<{ choices: OptionChoice[]; meta: Map<string, ClaudeModelMeta> }>((resolve, reject) => {
      // Claude startup can exceed 12s under heavy system load; the cache
      // makes this a rare cold-path cost, so give it generous headroom.
      const timer = setTimeout(() => reject(new Error("claude model list timed out")), 30_000);
      readLines(proc.stdout, (line) => {
        const ev = tryParse(line);
        if (ev?.type !== "control_response") return;
        const response = ev.response;
        if (response?.request_id !== "cmux-list-options") return;
        clearTimeout(timer);
        if (response.subtype !== "success") reject(new Error(response.error ?? response.message ?? "claude list_models failed"));
        else resolve(normalizeModelCatalog(response.response?.models, version));
      }, () => {
        clearTimeout(timer);
        reject(new Error("claude exited while listing models"));
      });
      proc.stdin.write(JSON.stringify({
        type: "control_request",
        request_id: "cmux-list-options",
        request: { subtype: "list_models" },
      }) + "\n");
      proc.stdin.flush();
    });
  } finally {
    proc.kill();
  }
}

function handleLine(sess: SessionCtx, line: string) {
  const ev = tryParse(line);
  if (!ev) return;
  if (ev.type === "control_response") {
    const st = state(sess);
    const requestId = ev.response?.request_id;
    const pending = requestId ? st.pending.get(requestId) : undefined;
    if (pending) {
      st.pending.delete(requestId);
      clearTimeout(pending.timer);
      pending.resolve(ev.response);
    }
    return;
  }
  switch (ev.type) {
    case "system":
      if (ev.subtype === "init") {
        const st = state(sess);
        st.commands = normalizeCommands(ev.slash_commands);
        sess.internal.providerSessionId = ev.session_id;
        const fork = sess.internal.claudeFork as { providerSessionId?: string } | undefined;
        if (fork && ev.session_id) fork.providerSessionId = ev.session_id;
        sess.emit({ kind: "meta", model: ev.model, providerSessionId: ev.session_id });
        if (st.commands.length) sess.emit({ kind: "commands", trigger: "/", commands: st.commands });
      } else if (ev.subtype === "status" && ev.permissionMode) {
        state(sess).permissionMode = String(ev.permissionMode);
        emitOptions(sess);
      }
      break;
    case "stream_event": {
      const e = ev.event;
      if (e?.type === "content_block_delta") {
        if (e.delta?.type === "text_delta" && e.delta.text) {
          sess.emit({ kind: "delta", text: e.delta.text });
        } else if (e.delta?.type === "thinking_delta" && e.delta.thinking) {
          sess.emit({ kind: "thinking", text: e.delta.thinking });
        }
      }
      break;
    }
    case "assistant": {
      for (const block of ev.message?.content ?? []) {
        if (block.type === "tool_use") {
          sess.emit({
            kind: "tool-start",
            toolId: block.id,
            name: block.name,
            detail: truncate(JSON.stringify(block.input ?? {})),
          });
        }
      }
      break;
    }
    case "user": {
      for (const block of ev.message?.content ?? []) {
        if (block.type === "tool_result") {
          const content = typeof block.content === "string"
            ? block.content
            : (block.content ?? []).map((c: any) => c.text ?? "").join("");
          sess.emit({
            kind: "tool-end",
            toolId: block.tool_use_id,
            ok: !block.is_error,
            detail: truncate(content, 400),
          });
        }
      }
      break;
    }
    case "result": {
      const stats = [
        ev.total_cost_usd != null ? `$${ev.total_cost_usd.toFixed(3)}` : null,
        ev.duration_ms != null ? `${(ev.duration_ms / 1000).toFixed(1)}s` : null,
        ev.num_turns != null ? `${ev.num_turns} turn${ev.num_turns === 1 ? "" : "s"}` : null,
      ].filter(Boolean).join(" · ");
      if (ev.is_error) {
        sess.emit({ kind: "error", message: truncate(String(ev.result ?? ev.subtype), 400) });
      }
      if (finishTurn(sess, stats) === 0) sess.setStatus("idle");
      break;
    }
  }
}

function normalizeCommands(commands: any): CommandEntry[] {
  if (!Array.isArray(commands)) return [];
  return commands.map((c) => ({
    name: String(c.name ?? c.command ?? "").replace(/^\/+/, ""),
    description: c.description ? String(c.description) : undefined,
    source: c.source ? String(c.source) : undefined,
  })).filter((c) => c.name);
}
