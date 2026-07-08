import {
  assetCacheStatsForTest,
  buildBundles,
  cssAsset,
  cssFontFamily,
  dirtyStateForTest,
  emitDoneAfterFilesForTest,
  emitSessionEventForTest,
  fileDiffAllowedForTest,
  filterChangedFilesSinceBaseline,
  filesChangedEventsForTest,
  gitFilesFromOutput,
  gitOutputWithCodes,
  gitOutputWithCodesResult,
  insertDeferredTurnEvents,
  recordFilesChangedForTest,
  recordTurnBaselineForTest,
  rebuildFileDiffAllowlistForTest,
  resetAssetCachesForTest,
  resolveFileDiffPath,
  sendPromptForTest,
  turnBaselineCountForTest,
  turnBaselineKeysForTest,
} from "../server";
import type { Adapter, AgentEvent, SessionCtx, SessionStatus } from "../types";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const priorDev = process.env.CMUX_AGENT_UI_DEV;
try {
  delete process.env.CMUX_AGENT_UI_DEV;
  resetAssetCachesForTest();
  const [firstBundles, secondBundles] = await Promise.all([buildBundles(), buildBundles()]);
  assert(firstBundles === secondBundles, "buildBundles should return the cached bundle map by default");
  assert(assetCacheStatsForTest().bundleBuildCount === 1, "buildBundles should build once by default");

  const firstCss = await cssAsset();
  const secondCss = await cssAsset();
  assert(firstCss === secondCss, "cssAsset should return the cached stylesheet by default");
  assert(assetCacheStatsForTest().cssReadCount === 1, "cssAsset should read once by default");
} finally {
  if (priorDev === undefined) delete process.env.CMUX_AGENT_UI_DEV;
  else process.env.CMUX_AGENT_UI_DEV = priorDev;
}

const cwd = "/tmp/agent-chat-path-test";
assert(resolveFileDiffPath(cwd, "src/../file.ts") === "file.ts", "normal in-cwd paths should normalize");
for (const path of ["src/../../x", "../x", "..", "a\0b"]) {
  let rejected = false;
  try {
    resolveFileDiffPath(cwd, path);
  } catch {
    rejected = true;
  }
  assert(rejected, `expected path to be rejected: ${path}`);
}

const fallback = `"Cascadia Code", monospace`;
const sanitized = cssFontFamily(`Bad";} body { color:red</style>, Good\\Name`, fallback);
assert(!/[;{}<>]/.test(sanitized), `sanitized font family should not contain CSS/HTML breakers: ${sanitized}`);
assert(sanitized.includes(`"Bad\\" body  color:red/style"`), `sanitized font family should escape quotes and strip angle brackets: ${sanitized}`);
assert(sanitized.includes(`"Good\\\\Name"`), `sanitized font family should escape backslashes: ${sanitized}`);

const root = join(import.meta.dir, "..", "scratch", "git-output-cap-test");
await rm(root, { recursive: true, force: true });
await mkdir(root, { recursive: true });
async function run(cmd: string[], cwd = root) {
  const p = Bun.spawn(cmd, { cwd, stdout: "pipe", stderr: "pipe", env: { ...process.env } });
  const [err, code] = await Promise.all([new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`${cmd.join(" ")} failed: ${err}`);
}
await run(["git", "init"]);
await writeFile(join(root, "big.txt"), "start\n");
await run(["git", "add", "big.txt"]);
await run(["git", "-c", "user.email=a@b.c", "-c", "user.name=agent", "commit", "-m", "init"]);
await writeFile(join(root, "big.txt"), Array.from({ length: 4000 }, (_, i) => `line ${i} ${"x".repeat(80)}`).join("\n") + "\n");
const cappedResult = await gitOutputWithCodesResult(root, ["diff", "--no-ext-diff", "HEAD", "--", "big.txt"], 4096, [0]);
assert(cappedResult.truncated, "large git output should carry truncation metadata");
assert(!cappedResult.text.includes("[truncated]"), "low-level git output should not append a display marker");
assert(new TextEncoder().encode(cappedResult.text).byteLength <= 4096, `large git output should stay within the cap, got ${cappedResult.text.length} chars`);
const capped = await gitOutputWithCodes(root, ["diff", "--no-ext-diff", "HEAD", "--", "big.txt"], 4096, [0]);
assert(!capped.includes("[truncated]"), "string git output should not append a display marker");
const files = gitFilesFromOutput({ text: "src/a.ts\nsrc/b.ts\npartial-or-marker", truncated: true });
assert(files.join("|") === "src/a.ts|src/b.ts", `truncated git files should drop torn final entries: ${files.join("|")}`);

let deadlineRejected = false;
try {
  await dirtyStateForTest(root, 0);
} catch (err) {
  deadlineRejected = /timed out/.test(String(err instanceof Error ? err.message : err));
}
assert(deadlineRejected, "dirty state should abort when its deadline has expired");

const orderedEvents: AgentEvent[] = [
  { kind: "user", text: "first" },
  { kind: "assistant", text: "first answer" },
  { kind: "user", text: "second" },
  { kind: "assistant", text: "second answer" },
];
const generations = [1, 1, 2, 2];
const inserted = insertDeferredTurnEvents(orderedEvents, generations, 1, [
  { kind: "files-changed", files: [{ path: "a.txt", adds: 1, dels: 0, status: "modified" }] },
  { kind: "done", stats: "1s" },
]);
assert(inserted.insertedAt === 2 && !inserted.dropped, `deferred finalization inserted at wrong position: ${JSON.stringify(inserted)}`);
assert(orderedEvents.map((evt) => evt.kind).join("|") === "user|assistant|files-changed|done|user|assistant", "deferred finalization should precede the newer user event");
assert(generations.join("|") === "1|1|1|1|2|2", `deferred generations were not preserved: ${generations.join("|")}`);
const dropped = insertDeferredTurnEvents(orderedEvents, generations, 1, [{ kind: "done" }]);
assert(dropped.dropped, "duplicate finalization should be dropped once the turn already has a footer");

const attributed = filterChangedFilesSinceBaseline(
  [
    { path: "preexisting.txt", adds: 1, dels: 0, status: "modified" },
    { path: "changed.txt", adds: 2, dels: 0, status: "modified" },
    { path: "new.txt", adds: 1, dels: 0, status: "added" },
  ],
  new Map([
    ["preexisting.txt", { status: "modified", signature: "aaa" }],
    ["changed.txt", { status: "modified", signature: "bbb" }],
  ]),
  new Map([
    ["preexisting.txt", { status: "modified", signature: "aaa" }],
    ["changed.txt", { status: "modified", signature: "ccc" }],
    ["new.txt", { status: "added", signature: "ddd" }],
  ]),
);
assert(attributed.map((f) => f.path).join("|") === "changed.txt|new.txt", `baseline filtering attributed wrong files: ${JSON.stringify(attributed)}`);

const noFilesRoot = join(import.meta.dir, "..", "scratch", "no-files-baseline-test");
await rm(noFilesRoot, { recursive: true, force: true });
await mkdir(noFilesRoot, { recursive: true });
const noFilesSession = {
  cwd: noFilesRoot,
  internal: {
    turnBaselines: new Map([[7, Promise.resolve({ files: new Map() })]]),
  },
};
await filesChangedEventsForTest(noFilesSession, 7, 500);
assert(turnBaselineCountForTest(noFilesSession) === 0, "no-files turn should retire its baseline");

const allowSession = { cwd: "/tmp/agent-chat-allowlist-test", internal: {} };
recordFilesChangedForTest(allowSession, [{ path: "reported.txt", adds: 1, dels: 0, status: "modified" }]);
assert(fileDiffAllowedForTest(allowSession, "reported.txt"), "reported files-changed path should be diff-allowed");
assert(!fileDiffAllowedForTest(allowSession, ".env"), "unreported path should not be diff-allowed");

const steerBaselineSession = { internal: {} };
for (let i = 1; i <= 9; i++) recordTurnBaselineForTest(steerBaselineSession, i);
assert(turnBaselineCountForTest(steerBaselineSession) === 4, `steered baselines should be bounded, got ${turnBaselineCountForTest(steerBaselineSession)}`);
assert(turnBaselineKeysForTest(steerBaselineSession).join("|") === "6|7|8|9", `newest steered baselines should be retained, got ${turnBaselineKeysForTest(steerBaselineSession).join("|")}`);

const steerRoot = join(import.meta.dir, "..", "scratch", "steer-attribution-test");
await rm(steerRoot, { recursive: true, force: true });
await mkdir(steerRoot, { recursive: true });
await writeFile(join(steerRoot, "tracked.txt"), "before\n");
await run(["git", "init"], steerRoot);
await run(["git", "add", "tracked.txt"], steerRoot);
await run(["git", "-c", "user.email=a@b.c", "-c", "user.name=agent", "commit", "-m", "init"], steerRoot);
let active = false;
let activeDoneGeneration: number | undefined;
let editedResolve!: () => void;
const edited = new Promise<void>((resolve) => { editedResolve = resolve; });
const adapter = {
  send: async (_sess: SessionCtx, prompt: string, generation?: number) => {
    if (!active) {
      active = true;
      activeDoneGeneration = generation;
      await writeFile(join(steerRoot, "tracked.txt"), `before\n${prompt}\n`);
      editedResolve();
    }
  },
  stop() {},
  dispose() {},
  setOption: async () => {},
  attributionMode: () => active ? "current-turn" : "new-turn",
} as Adapter & { attributionMode: () => "new-turn" | "current-turn" };
const steerSession = {
  id: "steer-test",
  provider: "test",
  cwd: steerRoot,
  title: "steer test",
  autoApprove: true,
  startOptions: {},
  status: "idle" as SessionStatus,
  events: [] as AgentEvent[],
  internal: {},
  adapter,
  sockets: new Set(),
  createdAt: Date.now(),
  emit(evt: AgentEvent) {
    if (evt.kind === "done") emitDoneAfterFilesForTest(this as any, evt);
    else emitSessionEventForTest(this as any, evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};
sendPromptForTest(steerSession as any, "edit-before-steer");
await edited;
sendPromptForTest(steerSession as any, "steer-text");
assert((steerSession.internal as any).turnGeneration === 1, `steer should not allocate a new generation, got ${String((steerSession.internal as any).turnGeneration)}`);
steerSession.emit({ kind: "done", generation: activeDoneGeneration } as any);
await ((steerSession.internal as any).pendingDoneEmit as Promise<void>);
const steerFiles = steerSession.events.find((evt) => evt.kind === "files-changed") as Extract<AgentEvent, { kind: "files-changed" }> | undefined;
assert(steerFiles?.files.some((file) => file.path === "tracked.txt"), `pre-steer edit should be attributed to the active turn: ${JSON.stringify(steerSession.events)}`);
assert(turnBaselineCountForTest(steerSession) === 0, "completed steered turn should retire its baseline");

const sequentialRoot = join(import.meta.dir, "..", "scratch", "sequential-attribution-test");
await rm(sequentialRoot, { recursive: true, force: true });
await mkdir(sequentialRoot, { recursive: true });
await writeFile(join(sequentialRoot, "first.txt"), "before\n");
await writeFile(join(sequentialRoot, "second.txt"), "before\n");
await run(["git", "init"], sequentialRoot);
await run(["git", "add", "first.txt", "second.txt"], sequentialRoot);
await run(["git", "-c", "user.email=a@b.c", "-c", "user.name=agent", "commit", "-m", "init"], sequentialRoot);
const sequentialDone: number[] = [];
const sequentialWaiters: (() => void)[] = [];
function waitForSequentialDone(): Promise<void> {
  return new Promise((resolve) => sequentialWaiters.push(resolve));
}
const sequentialAdapter = {
  send: async (sess: SessionCtx, prompt: string, generation?: number) => {
    const file = prompt.includes("second") ? "second.txt" : "first.txt";
    await writeFile(join(sequentialRoot, file), `before\n${prompt}\n`);
    sequentialDone.push(generation ?? 0);
    sess.emit({ kind: "done", generation } as any);
    sequentialWaiters.shift()?.();
  },
  stop() {},
  dispose() {},
  setOption: async () => {},
} as Adapter;
const sequentialSession = {
  id: "sequential-test",
  provider: "test",
  cwd: sequentialRoot,
  title: "sequential test",
  autoApprove: true,
  startOptions: {},
  status: "idle" as SessionStatus,
  events: [] as AgentEvent[],
  internal: {},
  adapter: sequentialAdapter,
  sockets: new Set(),
  createdAt: Date.now(),
  emit(evt: AgentEvent) {
    if (evt.kind === "done") emitDoneAfterFilesForTest(this as any, evt as any);
    else emitSessionEventForTest(this as any, evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};
const firstSequentialDone = waitForSequentialDone();
sendPromptForTest(sequentialSession as any, "first turn");
await firstSequentialDone;
await ((sequentialSession.internal as any).pendingDoneEmit as Promise<void>);
const secondSequentialDone = waitForSequentialDone();
sendPromptForTest(sequentialSession as any, "second turn");
await secondSequentialDone;
await ((sequentialSession.internal as any).pendingDoneEmit as Promise<void>);
const sequentialFileBlocks = sequentialSession.events.filter((evt) => evt.kind === "files-changed") as Extract<AgentEvent, { kind: "files-changed" }>[];
assert(sequentialDone.join("|") === "1|2", `adapter should receive explicit generations, got ${sequentialDone.join("|")}`);
assert(sequentialFileBlocks[0]?.files.some((file) => file.path === "first.txt"), `first turn should attribute first.txt: ${JSON.stringify(sequentialSession.events)}`);
assert(sequentialFileBlocks[1]?.files.some((file) => file.path === "second.txt"), `second turn should attribute second.txt: ${JSON.stringify(sequentialSession.events)}`);

const forkedSession = {
  cwd: "/tmp/agent-chat-fork-allowlist-test",
  events: [{ kind: "files-changed", files: [{ path: "copied.txt", adds: 1, dels: 0, status: "modified" }] }] as AgentEvent[],
  internal: {},
};
rebuildFileDiffAllowlistForTest(forkedSession);
assert(fileDiffAllowedForTest(forkedSession, "copied.txt"), "forked sessions should allow diffs from copied files-changed history");

console.log("server utility assertions passed");
