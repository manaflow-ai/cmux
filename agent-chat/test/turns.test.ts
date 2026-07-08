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

const heights = new Map<number, number>([[0, 100], [1, 100], [2, 100], [3, 100]]);
const range = virtualRange(10, heights, 250, 300, 100, 1);
if (range.start > 2 || range.end < 5 || range.total !== 1000) {
  throw new Error(`unexpected virtual range: ${JSON.stringify(range)}`);
}

console.log("turn summary and virtualization: OK");
