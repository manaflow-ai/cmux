import type { Block } from "../src/session";
import { activityRowLabel, groupTurns, summarizeTurnActivity } from "../src/turns";
import { measureVirtualRow, measureVirtualRowFromResize, scrollCompensationDelta, virtualRange } from "../src/hooks/useVirtualTurns";

(globalThis as any).location ??= { pathname: "/" };
const { disclosureHeightKeyframes, disclosureShouldRender, disclosureSnapshotStyle } = await import("../src/components/Transcript");

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
const measuredDelta = scrollCompensationDelta(1, 3, 100, 135, 260);
if (measuredDelta !== 35) {
  throw new Error(`measurement above anchor should compensate by exact delta, got ${measuredDelta}`);
}
const estimatedDelta = scrollCompensationDelta(1, 3, undefined, 220, 260);
if (estimatedDelta !== -40) {
  throw new Error(`first measurement above anchor should compensate against estimate, got ${estimatedDelta}`);
}
const visibleDelta = scrollCompensationDelta(3, 3, 100, 140, 260);
if (visibleDelta !== 0) {
  throw new Error(`measurement at/after anchor should not compensate, got ${visibleDelta}`);
}
const remeasureVersions = { current: 0 };
let rowHeight = 340;
const rowEvents = new EventTarget();
const animatingRow = Object.assign(rowEvents, {
  getBoundingClientRect: () => ({ height: rowHeight }) as DOMRect,
  querySelector: (selector: string) => selector === '[data-disclosure-animating="true"]' ? ({} as Element) : null,
});
const remeasureState = {
  heights: new Map<number, number>([[0, 100]]),
  measured: { current: { total: 100, count: 1 } },
  estimate: { current: 100 },
  anchorIndex: { current: 1 },
  scrollRef: { current: { scrollTop: 0 } as HTMLElement },
  bumpVersion: () => { remeasureVersions.current += 1; },
};
const remeasureVersionCount = () => remeasureVersions.current;
if (measureVirtualRowFromResize(0, animatingRow, remeasureState)) {
  throw new Error("ResizeObserver path should not remeasure while a disclosure is animating");
}
if (remeasureState.heights.get(0) !== 100 || remeasureVersionCount() !== 0) {
  throw new Error("ResizeObserver guard should leave the cached row height unchanged during animation");
}
animatingRow.addEventListener("virtual-row-remeasure", () => {
  measureVirtualRow(0, animatingRow, remeasureState);
});
animatingRow.dispatchEvent(new Event("virtual-row-remeasure"));
if (remeasureState.heights.get(0) !== rowHeight || remeasureVersionCount() !== 1) {
  throw new Error(`explicit disclosure remeasure should update while animating, got height ${remeasureState.heights.get(0)} versions ${remeasureVersionCount()}`);
}
if (remeasureState.scrollRef.current.scrollTop !== 240) {
  throw new Error(`remeasure above anchor should preserve scroll position with delta, got ${remeasureState.scrollRef.current.scrollTop}`);
}
if (!disclosureShouldRender(true, false) || !disclosureShouldRender(false, true) || disclosureShouldRender(false, false)) {
  throw new Error("disclosure presence state should keep children mounted while opening or closing only");
}
const interruptedOpen = disclosureHeightKeyframes(true, 42, 180);
if (interruptedOpen[0].height !== "42px" || interruptedOpen[1].height !== "180px") {
  throw new Error(`disclosure open should animate from current measured height to target: ${JSON.stringify(interruptedOpen)}`);
}
const interruptedClose = disclosureHeightKeyframes(false, 77, 180);
if (interruptedClose[0].height !== "77px" || interruptedClose[1].height !== "0px") {
  throw new Error(`disclosure close should animate from current measured height to zero: ${JSON.stringify(interruptedClose)}`);
}
// Browser verification is still needed for actual WAAPI cleanup timing; Bun has no animation engine here.
const midCloseSnapshot = disclosureSnapshotStyle("110px", 149, "0.42");
if (midCloseSnapshot.height !== "110px" || midCloseSnapshot.opacity !== "0.42") {
  throw new Error(`disclosure cleanup should preserve the mid-flight computed style: ${JSON.stringify(midCloseSnapshot)}`);
}
const reopenFromMidClose = disclosureHeightKeyframes(true, Number.parseFloat(midCloseSnapshot.height), 149, Number.parseFloat(midCloseSnapshot.opacity));
if (reopenFromMidClose[0].height !== "110px" || reopenFromMidClose[0].opacity !== 0.42 || reopenFromMidClose[1].height !== "149px") {
  throw new Error(`interrupted reopen should continue from current height instead of snap to start: ${JSON.stringify(reopenFromMidClose)}`);
}

console.log("turn summary and virtualization: OK");
