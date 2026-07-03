// Common event schema every adapter normalizes into. The UI only knows this.
export type AgentEvent =
  | { kind: "meta"; model?: string; providerSessionId?: string }
  | { kind: "user"; text: string }
  | { kind: "status"; text: string }
  | { kind: "delta"; text: string } // streaming assistant text
  | { kind: "assistant"; text: string } // full assistant message (non-streaming providers)
  | { kind: "thinking"; text: string } // streaming reasoning text
  | { kind: "tool-start"; toolId: string; name: string; detail?: string }
  | { kind: "tool-end"; toolId: string; name?: string; detail?: string; ok?: boolean }
  | { kind: "done"; stats?: string }
  | { kind: "error"; message: string };

export type SessionStatus = "idle" | "running" | "exited" | "error";

export interface SessionCtx {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  autoApprove: boolean;
  status: SessionStatus;
  events: AgentEvent[];
  // Adapter-private state (child proc, provider session/thread ids, rpc counters).
  internal: Record<string, unknown>;
  emit(evt: AgentEvent): void;
  setStatus(status: SessionStatus): void;
}

export interface Adapter {
  send(sess: SessionCtx, prompt: string): void | Promise<void>;
  stop(sess: SessionCtx): void;
  dispose(sess: SessionCtx): void;
}

export interface ProviderDef {
  id: string;
  label: string;
  adapter: string; // key into the adapter registry
  // Extra spawn config consumed by the adapter.
  cmd?: string[];
  autoApproveArgs?: string[];
}
