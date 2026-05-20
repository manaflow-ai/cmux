import type { AgentEvent } from "./types";
import { makeClientId } from "./ids";

type NativeReply<T> =
  | { ok: true; value: T }
  | { ok: false; error?: { message?: string } };

type EventListener = (event: AgentEvent) => void;

declare global {
  interface Window {
    cmuxAgentBridge?: {
      receive(event: AgentEvent): void;
    };
    webkit?: {
      messageHandlers?: {
        agentSession?: {
          postMessage(message: unknown): Promise<NativeReply<unknown>>;
        };
      };
    };
  }
}

const listeners = new Set<EventListener>();

if (typeof window !== "undefined") {
  window.cmuxAgentBridge = {
    receive(event: AgentEvent) {
      for (const listener of [...listeners]) {
        listener(event);
      }
    },
  };
}

export function subscribeToAgentEvents(listener: EventListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export async function callNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (typeof window === "undefined") {
    throw new Error("Native bridge is unavailable.");
  }
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler || typeof handler.postMessage !== "function") {
    throw new Error("Native bridge is unavailable.");
  }

  const reply = (await handler.postMessage({
    id: makeClientId(),
    method,
    params,
  })) as NativeReply<T>;

  if (!reply.ok) {
    throw new Error(reply.error?.message || "Native bridge request failed.");
  }

  return reply.value;
}
