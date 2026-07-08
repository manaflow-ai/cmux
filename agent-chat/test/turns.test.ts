import type { Block } from "../src/session";
import { activityRowLabel, groupTurns, summarizeTurnActivity } from "../src/turns";
import { virtualRange } from "../src/hooks/useVirtualTurns";

const activity: Block[] = [
  { kind: "tool", toolId: "read", name: "cat", detail: "AGENTS.md", status: "ok" },
  { kind: "tool", toolId: "search", name: "rg", detail: "RepositoryPicker", status: "ok" },
  { kind: "tool", toolId: "list", name: "ls", detail: "Sources", status: "ok" },
  { kind: "files", files: [
    { path: "RepositoryPicker.tsx", adds: 1, dels: 1, status: "modified" },
    { path: "WorkspaceView.swift", adds: 2, dels: 0, status: "modified" },
  ] },
];

const summary = summarizeTurnActivity(activity);
if (summary !== "Edited 2 files, read 1 file, searched code, listed files, and ran 3 commands") {
  throw new Error(`unexpected summary: ${summary}`);
}
if (/Read 1 File|Searched Code|Listed Files|Ran 3 Commands/.test(summary)) {
  throw new Error(`summary regressed to title case: ${summary}`);
}
const labels = activity.map((block) => activityRowLabel(block));
if (labels.join("|") !== "Read AGENTS.md|Searched RepositoryPicker|Listed Sources|Edited 2 files") {
  throw new Error(`unexpected activity labels: ${labels.join("|")}`);
}

const groups = groupTurns([
  { kind: "user", text: "first" },
  ...activity,
  { kind: "assistant", text: "done", open: false },
  { kind: "footer", text: "1s" },
], "idle");
if (groups.length !== 1 || !groups[0].done || groups[0].activity.length !== activity.length) {
  throw new Error("turn grouping failed");
}
if (groups[0].assistant?.text !== "done") {
  throw new Error("single-segment turn lost its primary assistant");
}

const multiSegment = groupTurns([
  { kind: "user", text: "inspect" },
  { kind: "assistant", text: "I'll inspect the files first.", open: false },
  { kind: "tool", toolId: "read", name: "cat", detail: "src/turns.ts", status: "ok" },
  { kind: "assistant", text: "I found the issue and fixed it.", open: false },
  { kind: "footer", text: "2s" },
], "idle");
if (multiSegment.length !== 1) throw new Error("multi-segment turn split unexpectedly");
if (multiSegment[0].assistant?.text !== "I found the issue and fixed it.") {
  throw new Error(`primary assistant should be the final segment: ${multiSegment[0].assistant?.text}`);
}
const ordered = multiSegment[0].activity.map((block) => block.kind === "assistant" ? block.text : block.kind === "tool" ? block.detail : block.kind).join("|");
if (ordered !== "I'll inspect the files first.|src/turns.ts") {
  throw new Error(`intermediate assistant/tool order was not preserved: ${ordered}`);
}

const lateFiles = { kind: "files" as const, files: [{ path: "src/turns.ts", adds: 2, dels: 1, status: "modified" }] };
const assistantThenFiles = groupTurns([
  { kind: "user", text: "late files" },
  { kind: "assistant", text: "Final answer stays visible.", open: false },
  lateFiles,
  { kind: "footer", text: "3s" },
], "idle");
if (assistantThenFiles[0].assistant?.text !== "Final answer stays visible.") {
  throw new Error("late files before footer demoted the final assistant");
}
if (assistantThenFiles[0].activity.at(-1)?.kind !== "files") {
  throw new Error("late files before footer were not attached as activity");
}

const footerThenFiles = groupTurns([
  { kind: "user", text: "replay order" },
  { kind: "assistant", text: "Replay answer stays visible.", open: false },
  { kind: "footer", text: "4s" },
  lateFiles,
], "idle");
if (footerThenFiles[0].assistant?.text !== "Replay answer stays visible.") {
  throw new Error("files after footer demoted the final assistant");
}
if (!footerThenFiles[0].footer || footerThenFiles[0].activity.at(-1)?.kind !== "files") {
  throw new Error("footer-then-files replay order was not preserved");
}

const heights = new Map<number, number>([[0, 100], [1, 100], [2, 100], [3, 100]]);
const range = virtualRange(10, heights, 250, 300, 100, 1);
if (range.start > 2 || range.end < 5 || range.total !== 1000) {
  throw new Error(`unexpected virtual range: ${JSON.stringify(range)}`);
}

console.log("turn summary and virtualization: OK");
