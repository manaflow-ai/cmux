// Terminal chat view: renders the JSONL transcript a terminal agent (Claude
// Code, Codex) writes as it runs, so a cmux terminal can be shown as a chat
// without starting a second agent process. The terminal stays the source of
// truth: this adapter tails the file and normalizes it into AgentEvent, and
// prompts and interrupts go to the terminal through the cmux control socket.
import { open, stat } from "node:fs/promises";
import type { Adapter, AgentEvent, OptionValue, SessionCtx } from "../types";
import { cmuxRpc, type CmuxRpcResult } from "../cmux-rpc";
import { tryParse, truncate } from "./lines";

export type TranscriptAgent = "claude" | "codex";

/** The terminal agent session a transcript view drives. */
export interface TranscriptTarget {
  agentSessionId: string;
  surfaceId?: string;
}

type Rpc = (method: string, params: Record<string, unknown>) => Promise<CmuxRpcResult>;
let rpc: Rpc = cmuxRpc;

export function setTranscriptRpcForTest(next: Rpc | null) {
  rpc = next ?? cmuxRpc;
}

export function transcriptTarget(sess: SessionCtx): TranscriptTarget | undefined {
  return sess.internal.transcriptTarget as TranscriptTarget | undefined;
}

/** Focuses the terminal pane that runs the agent (for prompts the view cannot answer). */
export async function focusTranscriptTerminal(sess: SessionCtx): Promise<CmuxRpcResult> {
  const surfaceId = transcriptTarget(sess)?.surfaceId;
  if (!surfaceId) return { ok: false, error: "The terminal for this session is unknown." };
  return rpc("surface.focus", { surface_id: surfaceId });
}

export interface TranscriptParser {
  readonly agent: TranscriptAgent;
  /** Latest session title the transcript reported (Claude `ai-title`, Codex thread name). */
  title?: string;
  /** Working directory the transcript reported, when any. */
  cwd?: string;
  parse(line: string): AgentEvent[];
}

export function transcriptParser(agent: TranscriptAgent): TranscriptParser {
  return agent === "codex" ? new CodexTranscriptParser() : new ClaudeTranscriptParser();
}

/** Parses a whole transcript; used by tests and the initial load. */
export function parseTranscriptText(agent: TranscriptAgent, text: string): { events: AgentEvent[]; title?: string; cwd?: string } {
  const parser = transcriptParser(agent);
  const events: AgentEvent[] = [];
  for (const line of text.split("\n")) {
    if (line.trim()) events.push(...parser.parse(line));
  }
  return { events, title: parser.title, cwd: parser.cwd };
}

// Tool inputs worth showing as the one-line activity detail, in priority order.
const TOOL_DETAIL_KEYS = ["command", "cmd", "file_path", "pattern", "path", "url", "query", "description", "prompt", "skill"];

export function toolDetail(input: unknown): string {
  if (input == null) return "";
  if (typeof input === "string") {
    const parsed = tryParse(input);
    if (parsed && typeof parsed === "object") return toolDetail(parsed);
    return truncate(input);
  }
  if (typeof input !== "object") return truncate(String(input));
  const record = input as Record<string, unknown>;
  for (const key of TOOL_DETAIL_KEYS) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return truncate(value);
    if (Array.isArray(value) && value.every((v) => typeof v === "string") && value.length) return truncate(value.join(" "));
  }
  return truncate(JSON.stringify(record));
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((c: any) => (typeof c === "string" ? c : typeof c?.text === "string" ? c.text : c?.type === "image" ? "[image]" : ""))
    .filter(Boolean)
    .join("\n");
}

function tagValue(text: string, tag: string): string | undefined {
  const match = text.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
  return match?.[1]?.trim();
}

// Claude Code wraps harness bookkeeping in pseudo-XML user messages. These are
// never something the person typed, so they are hidden from the transcript.
const CLAUDE_HIDDEN_USER_TAGS = /^<(system-reminder|local-command-caveat|user-prompt-submit-hook|agent-message)>/;

class ClaudeTranscriptParser implements TranscriptParser {
  readonly agent = "claude" as const;
  title?: string;
  cwd?: string;
  private seen = new Set<string>();
  private turnOpen = false;
  private endedMessageIds = new Set<string>();

  parse(line: string): AgentEvent[] {
    const events = this.parseLine(line);
    for (const evt of events) {
      if (evt.kind === "done") this.turnOpen = false;
      else if (evt.kind !== "status") this.turnOpen = true;
    }
    return events;
  }

  /** Appends a turn end unless the turn already ended. */
  private endTurn(events: AgentEvent[], stats?: string): AgentEvent[] {
    const open = this.turnOpen || events.some((e) => e.kind !== "status");
    return open ? [...events, stats ? { kind: "done", stats } : { kind: "done" }] : events;
  }

  private parseLine(line: string): AgentEvent[] {
    const ev = tryParse(line);
    if (!ev || typeof ev !== "object") return [];
    if (ev.isSidechain) return [];
    if (typeof ev.cwd === "string" && ev.cwd) this.cwd = ev.cwd;
    // Claude rewrites nothing, but resumed sessions can replay an entry; a
    // uuid seen before is ignored so the view does not duplicate turns.
    if (typeof ev.uuid === "string") {
      if (this.seen.has(ev.uuid)) return [];
      this.seen.add(ev.uuid);
    }
    switch (ev.type) {
      case "ai-title":
        if (typeof ev.aiTitle === "string" && ev.aiTitle.trim()) this.title = ev.aiTitle.trim();
        return [];
      case "summary":
        if (typeof ev.summary === "string" && ev.summary.trim() && !this.title) this.title = ev.summary.trim();
        return [];
      case "user":
        return this.user(ev);
      case "assistant":
        return this.assistant(ev);
      case "system":
        return this.system(ev);
      default:
        return [];
    }
  }

  private user(ev: any): AgentEvent[] {
    if (ev.isMeta || ev.isCompactSummary || ev.isVisibleInTranscriptOnly) return [];
    const originKind = ev.origin?.kind;
    const content = ev.message?.content;
    if (originKind === "task-notification") {
      const text = typeof content === "string" ? content : textOf(content);
      const summary = tagValue(text, "summary") ?? tagValue(text, "status");
      return [{ kind: "status", text: summary ? `Background task: ${truncate(summary, 160)}` : "Background task update" }];
    }
    if (originKind && originKind !== "human") return [];
    const out: AgentEvent[] = [];
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block?.type !== "tool_result") continue;
        const result = textOf(block.content);
        out.push({ kind: "tool-end", toolId: String(block.tool_use_id ?? ""), ok: !block.is_error, detail: truncate(result, 400) });
      }
      // Claude often stores a typed prompt after injected reminder blocks in
      // the same message, so hidden blocks are dropped one by one.
      const prompt = content.filter((b: any) =>
        b?.type === "image" || (b?.type === "text" && typeof b.text === "string" && !CLAUDE_HIDDEN_USER_TAGS.test(b.text.trim())));
      if (prompt.length) out.push(...this.prompt(textOf(prompt)));
      return out;
    }
    if (typeof content === "string") return this.prompt(content);
    return out;
  }

  private prompt(raw: string): AgentEvent[] {
    const text = raw.trim();
    if (!text) return [];
    if (text.startsWith("[Request interrupted by user")) return this.endTurn([{ kind: "status", text: "Interrupted" }]);
    if (CLAUDE_HIDDEN_USER_TAGS.test(text)) return [];
    const command = tagValue(text, "command-name");
    if (command) {
      const args = tagValue(text, "command-args");
      return [{ kind: "user", text: args ? `${command} ${args}` : command }];
    }
    const stdout = tagValue(text, "local-command-stdout");
    if (stdout !== undefined) return stdout ? [{ kind: "status", text: truncate(stdout, 200) }] : [];
    const bash = tagValue(text, "bash-input");
    if (bash !== undefined) return [{ kind: "user", text: `! ${bash}` }];
    if (text.startsWith("<bash-stdout>") || text.startsWith("<bash-stderr>")) {
      const output = [tagValue(text, "bash-stdout"), tagValue(text, "bash-stderr")].filter(Boolean).join("\n");
      return output ? [{ kind: "status", text: truncate(output, 200) }] : [];
    }
    return [{ kind: "user", text }];
  }

  private assistant(ev: any): AgentEvent[] {
    const out: AgentEvent[] = [];
    const content = ev.message?.content;
    if (ev.isApiErrorMessage) {
      const message = textOf(content);
      return message ? [{ kind: "error", message: truncate(message, 400) }] : [];
    }
    if (typeof content === "string") {
      if (content.trim()) out.push({ kind: "assistant", text: content });
    } else if (Array.isArray(content)) {
      out.push(...this.assistantBlocks(content));
    }
    // `turn_duration` is only written for some turns; the final assistant
    // message's stop reason marks the end of every turn. Each content block
    // is its own line carrying the message's stop reason, and thinking comes
    // before the text, so the turn ends at the message's first text line.
    const stop = ev.message?.stop_reason;
    const messageId = String(ev.message?.id ?? ev.uuid ?? "");
    const hasText = out.some((e) => e.kind === "assistant");
    if ((stop === "end_turn" || stop === "stop_sequence") && hasText && !this.endedMessageIds.has(messageId)) {
      this.endedMessageIds.add(messageId);
      return this.endTurn(out);
    }
    return out;
  }

  private assistantBlocks(content: any[]): AgentEvent[] {
    const out: AgentEvent[] = [];
    for (const block of content) {
      if (block?.type === "text" && typeof block.text === "string" && block.text.trim()) {
        out.push({ kind: "assistant", text: block.text });
      } else if (block?.type === "thinking" && typeof block.thinking === "string" && block.thinking.trim()) {
        out.push({ kind: "thinking", text: block.thinking });
      } else if (block?.type === "tool_use" || block?.type === "server_tool_use") {
        out.push({ kind: "tool-start", toolId: String(block.id ?? ""), name: String(block.name ?? "tool"), detail: toolDetail(block.input) });
      }
    }
    return out;
  }

  private system(ev: any): AgentEvent[] {
    switch (ev.subtype) {
      case "turn_duration": {
        const ms = Number(ev.durationMs);
        return this.endTurn([], Number.isFinite(ms) && ms > 0 ? `${(ms / 1000).toFixed(1)}s` : undefined);
      }
      case "compact_boundary":
        return [{ kind: "status", text: "Conversation compacted" }];
      case "api_error":
        return [{ kind: "error", message: truncate(String(ev.content ?? ev.error?.message ?? "API error"), 400) }];
      default:
        return [];
    }
  }
}

// Codex rollout files mix three generations of records: `event_msg` user and
// agent messages, `response_item` model items, and newer `item_completed`
// events. Model items carry tools and reasoning; user prompts come from the
// event records because response_item user messages include injected context.
class CodexTranscriptParser implements TranscriptParser {
  readonly agent = "codex" as const;
  title?: string;
  cwd?: string;
  private lastUser?: string;
  private sinceUser = 0;

  parse(line: string): AgentEvent[] {
    const ev = tryParse(line);
    if (!ev || typeof ev !== "object") return [];
    const payload = ev.payload ?? {};
    switch (ev.type) {
      case "session_meta":
        if (typeof payload.cwd === "string") this.cwd = payload.cwd;
        return [];
      case "turn_context":
        if (typeof payload.cwd === "string") this.cwd = payload.cwd;
        return [];
      case "compacted":
        return this.track([{ kind: "status", text: "Conversation compacted" }]);
      case "event_msg":
        return this.track(this.eventMsg(payload));
      case "response_item":
        return this.track(this.responseItem(payload));
      default:
        return [];
    }
  }

  private track(events: AgentEvent[]): AgentEvent[] {
    for (const evt of events) {
      if (evt.kind === "user") {
        this.lastUser = evt.text;
        this.sinceUser = 0;
      } else {
        this.sinceUser++;
      }
    }
    return events;
  }

  private user(text: unknown): AgentEvent[] {
    const value = typeof text === "string" ? text.trim() : "";
    if (!value) return [];
    // The same prompt is recorded by both `user_message` and `item_completed`.
    if (value === this.lastUser && this.sinceUser === 0) return [];
    return [{ kind: "user", text: value }];
  }

  private eventMsg(payload: any): AgentEvent[] {
    switch (payload.type) {
      case "user_message":
        return this.user(payload.message);
      case "item_completed":
        if (payload.item?.type === "UserMessage") return this.user(textOf(payload.item.content));
        return [];
      case "task_complete":
        return [{ kind: "done" }];
      case "turn_aborted":
        return [{ kind: "status", text: "Interrupted" }, { kind: "done" }];
      case "error":
        return [{ kind: "error", message: truncate(String(payload.message ?? "error"), 400) }];
      case "thread_name_updated":
        if (typeof payload.thread_name === "string" && payload.thread_name.trim()) this.title = payload.thread_name.trim();
        return [];
      default:
        return [];
    }
  }

  private responseItem(payload: any): AgentEvent[] {
    switch (payload.type) {
      case "message": {
        if (payload.role !== "assistant") return [];
        const text = textOf(payload.content).trim();
        return text ? [{ kind: "assistant", text }] : [];
      }
      case "reasoning": {
        const text = Array.isArray(payload.summary) ? textOf(payload.summary).trim() : "";
        return text ? [{ kind: "thinking", text }] : [];
      }
      case "function_call":
      case "custom_tool_call":
      case "local_shell_call": {
        const input = payload.arguments ?? payload.input ?? payload.action;
        return [{ kind: "tool-start", toolId: String(payload.call_id ?? payload.id ?? ""), name: String(payload.name ?? "shell"), detail: toolDetail(input) }];
      }
      case "function_call_output":
      case "custom_tool_call_output": {
        const output = typeof payload.output === "string" ? payload.output : textOf(payload.output?.content ?? payload.output);
        return [{ kind: "tool-end", toolId: String(payload.call_id ?? ""), detail: truncate(output, 400) }];
      }
      default:
        return [];
    }
  }
}

// Initial loads read at most this much from the end of a transcript; long
// sessions start at a line boundary inside the window.
export const TRANSCRIPT_INITIAL_WINDOW_BYTES = 8 * 1024 * 1024;
const TRANSCRIPT_POLL_MS = 500;
const TRANSCRIPT_READ_CHUNK = 1024 * 1024;

/** Follows an append-only JSONL file by offset, delivering complete lines. */
export class TranscriptTail {
  private offset = -1;
  private pending = "";
  private timer: ReturnType<typeof setInterval> | null = null;
  private inflight: Promise<void> | null = null;
  private decoder = new TextDecoder();

  constructor(
    readonly path: string,
    private readonly onLines: (lines: string[], mtimeMs: number) => void,
    private readonly opts: { pollMs?: number; initialWindowBytes?: number } = {},
  ) {}

  start() {
    if (this.timer) return;
    // A transcript that stops being readable between stat and open (deleted,
    // or a root-owned file) must not reject out of the timer: an unhandled
    // rejection ends the whole sidecar. The next poll tries again.
    const tick = () => void this.poll().catch(() => {});
    tick();
    this.timer = setInterval(tick, this.opts.pollMs ?? TRANSCRIPT_POLL_MS);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** Reads everything appended since the last poll; joins a read in flight. */
  poll(): Promise<void> {
    if (!this.inflight) {
      this.inflight = this.read().finally(() => {
        this.inflight = null;
      });
    }
    return this.inflight;
  }

  private async read(): Promise<void> {
    const info = await stat(this.path).catch(() => null);
    if (!info) return;
    let skipPartialFirstLine = false;
    if (this.offset < 0) {
      const window = this.opts.initialWindowBytes ?? TRANSCRIPT_INITIAL_WINDOW_BYTES;
      this.offset = Math.max(0, info.size - window);
      skipPartialFirstLine = this.offset > 0;
    } else if (info.size < this.offset) {
      // Truncated or replaced: follow the new file from its start.
      this.offset = 0;
      this.pending = "";
      this.decoder = new TextDecoder();
    }
    if (info.size === this.offset) return;
    const handle = await open(this.path, "r");
    try {
      const buf = new Uint8Array(TRANSCRIPT_READ_CHUNK);
      while (this.offset < info.size) {
        const { bytesRead } = await handle.read(buf, 0, Math.min(buf.length, info.size - this.offset), this.offset);
        if (bytesRead <= 0) break;
        this.offset += bytesRead;
        this.pending += this.decoder.decode(buf.subarray(0, bytesRead), { stream: true });
        if (skipPartialFirstLine) {
          const nl = this.pending.indexOf("\n");
          if (nl < 0) continue;
          this.pending = this.pending.slice(nl + 1);
          skipPartialFirstLine = false;
        }
        const lastNl = this.pending.lastIndexOf("\n");
        if (lastNl < 0) continue;
        const lines = this.pending.slice(0, lastNl).split("\n").filter((l) => l.trim());
        this.pending = this.pending.slice(lastNl + 1);
        if (lines.length) this.onLines(lines, info.mtimeMs);
      }
    } finally {
      await handle.close();
    }
  }
}

// A turn counts as running while its last event is not a turn end and the
// transcript was written recently; Claude and Codex both flush per item.
export const TRANSCRIPT_ACTIVE_WINDOW_MS = 30_000;

export function transcriptLooksRunning(events: AgentEvent[], lastWriteMs: number, now = Date.now()): boolean {
  if (now - lastWriteMs > TRANSCRIPT_ACTIVE_WINDOW_MS) return false;
  for (let i = events.length - 1; i >= 0; i--) {
    const kind = events[i].kind;
    if (kind === "done") return false;
    if (kind === "user" || kind === "tool-start" || kind === "tool-end" || kind === "thinking" || kind === "assistant" || kind === "status") return true;
  }
  return false;
}

interface TranscriptState {
  tail: TranscriptTail;
  parser: TranscriptParser;
  lastWriteMs: number;
  statusTimer: ReturnType<typeof setInterval>;
}

function transcriptState(sess: SessionCtx): TranscriptState | undefined {
  return sess.internal.transcript as TranscriptState | undefined;
}

/**
 * Starts tailing `path` into `sess`. `onTitle` fires when the transcript
 * reports a new title so the server can refresh the page title.
 */
export function attachTranscript(
  sess: SessionCtx,
  agent: TranscriptAgent,
  path: string,
  onTitle?: (title: string) => void,
  opts: { pollMs?: number; initialWindowBytes?: number; onTick?: () => void } = {},
): TranscriptTail {
  const parser = transcriptParser(agent);
  const refreshStatus = () => {
    const st = transcriptState(sess);
    if (!st) return;
    sess.setStatus(transcriptLooksRunning(sess.events, st.lastWriteMs) ? "running" : "idle");
    opts.onTick?.();
  };
  const tail = new TranscriptTail(path, (lines, mtimeMs) => {
    const st = transcriptState(sess);
    // Activity comes from the file's own write time, so a transcript that
    // went idle long ago does not look busy when its history first loads.
    if (st) st.lastWriteMs = mtimeMs;
    const title = parser.title;
    for (const line of lines) {
      for (const evt of parser.parse(line)) sess.emit(evt);
    }
    if (parser.title && parser.title !== title) onTitle?.(parser.title);
    refreshStatus();
  }, opts);
  const state: TranscriptState = {
    tail,
    parser,
    lastWriteMs: 0,
    statusTimer: setInterval(refreshStatus, 2_000),
  };
  sess.internal.transcript = state;
  sess.internal.transcriptPath = path;
  tail.start();
  return tail;
}

export const transcriptAdapter: Adapter = {
  // The prompt is typed into the terminal's agent (bracketed paste + submit,
  // the delivery the iOS chat uses). The transcript then records it, which is
  // what renders the user message, so nothing is emitted here on success.
  async send(sess: SessionCtx, prompt: string) {
    const target = transcriptTarget(sess);
    if (!target) {
      sess.emit({ kind: "error", message: "This view is not attached to a terminal session.", prompt });
      return;
    }
    const res = await rpc("mobile.chat.send", { session_id: target.agentSessionId, text: prompt });
    if (!res.ok) sess.emit({ kind: "error", message: `Couldn't send to the terminal: ${res.error}`, prompt });
  },
  stop(sess: SessionCtx) {
    const target = transcriptTarget(sess);
    if (!target) return;
    void rpc("mobile.chat.interrupt", { session_id: target.agentSessionId }).then((res) => {
      if (!res.ok) sess.emit({ kind: "error", message: `Couldn't interrupt the terminal: ${res.error}` });
    });
  },
  dispose(sess: SessionCtx) {
    const st = transcriptState(sess);
    if (!st) return;
    st.tail.stop();
    clearInterval(st.statusTimer);
    delete sess.internal.transcript;
  },
  async setOption(_sess: SessionCtx, _id: string, _value: OptionValue) {
    throw new Error("operation is not supported in a transcript view");
  },
  capabilities: { options: [], triggers: [] },
};
