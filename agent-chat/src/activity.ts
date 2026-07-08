import type { Block } from "./session";

export interface ActivityIndicator {
  show: boolean;
  label: "Thinking" | "Reasoning";
}

export function activityIndicatorState(status: string | undefined, blocks: Block[]): ActivityIndicator {
  if (status !== "running") return { show: false, label: "Thinking" };
  const tail = blocks[blocks.length - 1];
  if (tail?.kind === "assistant" && tail.open) return { show: false, label: "Thinking" };
  if (tail?.kind === "tool" && tail.status === "running") return { show: false, label: "Thinking" };
  if (tail?.kind === "thinking" && tail.open) return { show: true, label: "Reasoning" };
  return { show: true, label: "Thinking" };
}

export function activityTailKey(blocks: Block[]): string {
  const tail = blocks[blocks.length - 1];
  if (!tail) return "empty";
  const prefix = `${blocks.length}:`;
  if (tail.kind === "assistant" || tail.kind === "thinking") return `${prefix}${tail.kind}:${tail.open}`;
  if (tail.kind === "tool") return `${prefix}${tail.kind}:${tail.toolId}:${tail.status}`;
  if (tail.kind === "footer" || tail.kind === "status" || tail.kind === "error" || tail.kind === "user") {
    return `${prefix}${tail.kind}`;
  }
  return "unknown";
}
