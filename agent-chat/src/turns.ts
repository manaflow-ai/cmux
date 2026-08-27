import type { Block } from "./session";

export interface TurnGroup {
  id: string;
  user?: Extract<Block, { kind: "user" }>;
  activity: Block[];
  assistant?: Extract<Block, { kind: "assistant" }>;
  footer?: Extract<Block, { kind: "footer" }>;
  done: boolean;
}

export function groupTurns(blocks: Block[], status?: string): TurnGroup[] {
  const groups: TurnGroup[] = [];
  let current: TurnGroup | null = null;
  let pendingAssistantIndex: number | null = null;
  const demoteAssistantToActivity = () => {
    if (current?.assistant) {
      const index = pendingAssistantIndex === null ? current.activity.length : Math.min(pendingAssistantIndex, current.activity.length);
      current.activity.splice(index, 0, current.assistant);
      current.assistant = undefined;
      pendingAssistantIndex = null;
    }
  };
  const push = () => {
    if (current && (current.user || current.activity.length || current.assistant || current.footer)) groups.push(current);
  };
  for (const block of blocks) {
    if (block.kind === "user") {
      push();
      current = { id: `turn-${groups.length}-${block.text.slice(0, 24)}`, user: block, activity: [], done: false };
      pendingAssistantIndex = null;
      continue;
    }
    if (!current) {
      current = { id: `turn-${groups.length}-prelude`, activity: [], done: false };
      pendingAssistantIndex = null;
    }
    if (block.kind === "assistant") {
      demoteAssistantToActivity();
      current.assistant = block;
      pendingAssistantIndex = current.activity.length;
    } else if (block.kind === "footer") {
      current.footer = block;
    } else {
      current.activity.push(block);
    }
  }
  push();
  return groups.map((group, index) => ({
    ...group,
    id: `${index}:${group.id}`,
    done: Boolean(group.footer || (status !== "running" && !group.assistant?.open && !group.activity.some((b) =>
      (b.kind === "tool" && b.status === "running") || (b.kind === "assistant" && b.open)
    ))),
  }));
}

function plural(n: number, one: string, many = `${one}s`) {
  return `${n} ${n === 1 ? one : many}`;
}

function joinSentence(parts: string[]) {
  if (!parts.length) return "No activity";
  if (parts.length === 1) return parts[0];
  if (parts.length === 2) return `${parts[0]} and ${parts[1]}`;
  return `${parts.slice(0, -1).join(", ")}, and ${parts[parts.length - 1]}`;
}

function sentenceCase(text: string) {
  return text ? text[0].toUpperCase() + text.slice(1) : text;
}

export function summarizeTurnActivity(blocks: Block[]): string {
  let edited = 0;
  let read = 0;
  let commands = 0;
  let searched = false;
  let listed = false;
  let other = 0;
  for (const block of blocks) {
    if (block.kind === "assistant") continue;
    if (block.kind === "files") {
      edited += block.files.length;
      continue;
    }
    if (block.kind !== "tool") {
      other++;
      continue;
    }
    commands++;
    const text = `${block.name} ${block.detail ?? ""}`.toLowerCase();
    if (/\b(read|cat|sed|nl|open)\b/.test(text)) read++;
    else if (/\b(rg|grep|search)\b/.test(text)) searched = true;
    else if (/\b(ls|find|list)\b/.test(text)) listed = true;
    else if (/\b(edit|write|apply_patch|patch)\b/.test(text)) edited++;
  }
  const parts: string[] = [];
  if (edited) parts.push(`edited ${plural(edited, "file")}`);
  if (read) parts.push(`read ${plural(read, "file")}`);
  if (searched) parts.push("searched code");
  if (listed) parts.push("listed files");
  if (commands) parts.push(`ran ${plural(commands, "command")}`);
  if (!commands && other) parts.push(`processed ${plural(other, "event")}`);
  return sentenceCase(joinSentence(parts));
}

export function activityRowLabel(block: Block): string {
  if (block.kind === "tool") {
    const name = block.name || "tool";
    const detail = block.detail ? ` ${block.detail}` : "";
    const lower = `${name}${detail}`.toLowerCase();
    if (/\b(rg|grep|search)\b/.test(lower)) return `Searched ${detail.trim() || name}`;
    if (/\b(read|cat|sed|nl|open)\b/.test(lower)) return `Read ${detail.trim() || name}`;
    if (/\b(ls|find|list)\b/.test(lower)) return `Listed ${detail.trim() || name}`;
    if (/\b(edit|write|apply_patch|patch)\b/.test(lower)) return `Edited ${detail.trim() || name}`;
    return `Ran ${name}${detail}`;
  }
  if (block.kind === "files") return `Edited ${plural(block.files.length, "file")}`;
  if (block.kind === "thinking") return "Reasoned";
  if (block.kind === "assistant") return "Assistant";
  if (block.kind === "status") return block.text;
  if (block.kind === "error") return "Error";
  return "Activity";
}
