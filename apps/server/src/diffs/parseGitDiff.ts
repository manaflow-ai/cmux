import type { DiffStatus, ReplaceDiffEntry } from "@cmux/shared/diff-types";
import { exec, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";
import { RepositoryManager } from "../repositoryManager.js";
import { serverLogger } from "../utils/fileLogger.js";

export interface ParsedDiffOptions {
  worktreePath: string;
  // If true, try to include file contents when under size limit
  includeContents?: boolean;
  // Max total size for patch + contents before omitting
  maxBytes?: number;
  // Optional: collector to receive detailed perf metrics
  perfOut?: ComputeEntriesPerf;
}

// NodeGit-only version: compute diff entries against HEAD and workdir (including index and untracked)
const execAsync = promisify(exec);

export type ComputeEntriesPerf = {
  baseRef?: string;
  compareBase?: string;
  tracked?: number;
  untracked?: number;
  entries?: number;
  resolveBaseMs: number;
  mergeBaseMs: number;
  listTrackedMs: number;
  listUntrackedMs: number;
  perFileBuildMs: number;
  numstatMs: number;
  patchMs: number;
  readOldMs: number;
  readNewMs: number;
  readUntrackedMs: number;
  totalMs: number;
  slowest?: { filePath: string; ms: number }[];
};

export async function computeEntriesNodeGit(
  opts: ParsedDiffOptions
): Promise<ReplaceDiffEntry[]> {
  const { worktreePath, includeContents = true, maxBytes = 950 * 1024 } = opts;

  const tStart = Date.now();
  // Resolve a primary/base ref: prefer the repo default branch (e.g., origin/main)
  const t0 = Date.now();
  const baseRef = await resolvePrimaryBaseRef(worktreePath);
  const tBaseRef = Date.now();
  const compareBase = await resolveMergeBaseWithDeepen(worktreePath, baseRef);
  const tMergeBase = Date.now();

  // Collect tracked changes vs baseRef (includes committed + staged + unstaged)
  const tracked = await getTrackedChanges(worktreePath, compareBase);
  const tTracked = Date.now();

  // Collect untracked files (relative to baseRef they are also additions)
  const untracked = await getUntrackedFiles(worktreePath);
  const tUntracked = Date.now();

  const entries: ReplaceDiffEntry[] = [];

  // Aggregated timing counters for per-file operations
  let timeNumstat = 0;
  let timePatch = 0;
  let timeReadOld = 0;
  let timeReadNew = 0;
  let timeReadUntracked = 0;
  let perFileBuildMs = 0;
  const slowFiles: { filePath: string; ms: number }[] = [];
  // Pre-fetch numstat for all tracked files in a single call
  const tNsGlobal0 = Date.now();
  const numstatMap = await getNumstatMap(worktreePath, compareBase);
  timeNumstat += Date.now() - tNsGlobal0;

  // Build a map of file -> full patch text in one git call to avoid N spawn cost
  const tP0All = Date.now();
  const patchMap = await getPatchMap(worktreePath, compareBase).catch(
    () => new Map<string, string>()
  );
  timePatch += Date.now() - tP0All;

  // Concurrency limit for per-file work
  const concurrency = Math.min(Math.max(os.cpus().length - 1, 2), 8);

  type BuildItem = {
    status: DiffStatus;
    fp: string;
    oldPath?: string;
    additions: number;
    deletions: number;
    isBinary: boolean;
    patchText?: string;
    patchSize: number;
    newContent?: string;
    newSize: number;
    needOld: boolean;
    oldFetchPath: string | null;
  };

  const trackedIntermediates: (BuildItem | null)[] = new Array(
    tracked.length
  ).fill(null);

  let idx = 0;
  const worker = async (): Promise<void> => {
    while (true) {
      const i = idx++;
      if (i >= tracked.length) return;
      const tFileStart = Date.now();
      const t = tracked[i]!;
      const { status, filePath: fp, oldPath } = t;
      let additions = 0;
      let deletions = 0;
      let isBinary = false;
      let patchText: string | undefined;
      let newContent: string | undefined;
      const isRename = status === "renamed";

      try {
        // additions/deletions from global numstat map
        const nd = numstatMap.get(fp) || null;
        if (nd) {
          additions = nd.additions;
          deletions = nd.deletions;
          isBinary = nd.isBinary;
        }

        if (!isBinary && !isRename) {
          if (includeContents) {
            if (status !== "deleted") {
              try {
                const tRn0 = Date.now();
                newContent = await fs.readFile(
                  path.join(worktreePath, fp),
                  "utf8"
                );
                timeReadNew += Date.now() - tRn0;
              } catch {
                newContent = "";
              }
            }
            // We'll batch old-content fetch later; just decide if needed
          }

          patchText = patchMap.get(fp);
        }
      } catch (err) {
        serverLogger.warn(
          `[Diffs] Failed building entry for ${fp}: ${String(err)}`
        );
      }

      const patchSize =
        !isBinary && patchText ? Buffer.byteLength(patchText, "utf8") : 0;
      const newSize = newContent ? Buffer.byteLength(newContent, "utf8") : 0;

      const needOld =
        !isBinary &&
        includeContents &&
        status !== "added" &&
        status !== "renamed" &&
        patchSize + newSize <= maxBytes;

      const oldFetchPath = needOld ? fp : null;

      trackedIntermediates[i] = {
        status,
        fp,
        oldPath,
        additions,
        deletions,
        isBinary,
        patchText,
        patchSize,
        newContent,
        newSize,
        needOld,
        oldFetchPath,
      };

      const tFileEnd = Date.now();
      const elapsed = tFileEnd - tFileStart;
      perFileBuildMs += elapsed;
      if (elapsed > 50) {
        slowFiles.push({ filePath: fp, ms: elapsed });
      }
    }
  };

  const workers: Promise<void>[] = [];
  for (let w = 0; w < concurrency; w++) workers.push(worker());
  await Promise.all(workers);

  // Batch-load old contents where needed
  const needOldPaths = trackedIntermediates
    .filter((x): x is BuildItem => !!x && x.needOld && !!x.oldFetchPath)
    .map((x) => x.oldFetchPath as string);
  let oldMap = new Map<string, string>();
  if (needOldPaths.length > 0) {
    const tOld0 = Date.now();
    oldMap = await gitShowFilesBatch(
      worktreePath,
      compareBase,
      needOldPaths
    ).catch(() => new Map());
    timeReadOld += Date.now() - tOld0;
  }

  for (const it of trackedIntermediates) {
    if (!it) continue;
    const {
      fp,
      oldPath,
      status,
      additions,
      deletions,
      isBinary,
      patchText,
      patchSize,
      newContent,
      newSize,
      oldFetchPath,
    } = it;
    let oldContent: string | undefined = undefined;
    let oldSize = 0;
    if (
      !isBinary &&
      status !== "added" &&
      status !== "renamed" &&
      includeContents
    ) {
      if (it.needOld) {
        oldContent = oldMap.get(oldFetchPath ?? fp) ?? "";
        oldSize = oldContent ? Buffer.byteLength(oldContent, "utf8") : 0;
      } else {
        oldContent = "";
        oldSize = 0;
      }
    }

    const totalApprox = patchSize + oldSize + newSize;
    const base: ReplaceDiffEntry = {
      filePath: fp,
      oldPath,
      status,
      additions,
      deletions,
      isBinary,
      patchSize,
      oldSize,
      newSize,
    };

    if (status === "renamed") {
      base.contentOmitted = includeContents ? true : false;
    } else if (!isBinary && includeContents) {
      if (totalApprox <= maxBytes) {
        base.patch = patchText;
        base.oldContent = oldContent;
        base.newContent = newContent;
        base.contentOmitted = false;
      } else {
        base.patch = patchSize < maxBytes ? patchText : undefined;
        base.contentOmitted = true;
      }
    } else {
      base.contentOmitted = false;
    }

    if (
      base.status === "modified" &&
      !base.isBinary &&
      base.additions === 0 &&
      base.deletions === 0 &&
      (!base.patch || base.patch.trim() === "")
    ) {
      continue;
    }
    entries.push(base);
  }

  // Handle untracked files as added with limited concurrency as well
  const untrackedConcurrency = Math.min(8, concurrency);
  let uIdx = 0;
  const uResults: ReplaceDiffEntry[] = [];
  const uWorker = async (): Promise<void> => {
    while (true) {
      const i = uIdx++;
      if (i >= untracked.length) return;
      const fp = untracked[i]!;
      let newContent = "";
      try {
        const tRn0 = Date.now();
        newContent = await fs.readFile(path.join(worktreePath, fp), "utf8");
        timeReadUntracked += Date.now() - tRn0;
      } catch {
        newContent = "";
      }
      const additions = newContent ? newContent.split("\n").length : 0;
      const newSize = Buffer.byteLength(newContent, "utf8");
      const base: ReplaceDiffEntry = {
        filePath: fp,
        status: "added",
        additions,
        deletions: 0,
        isBinary: false,
        newSize,
        oldSize: 0,
        patchSize: 0,
      };
      if (includeContents && newSize <= maxBytes) {
        base.oldContent = "";
        base.newContent = newContent;
        base.contentOmitted = false;
      } else if (includeContents) {
        base.contentOmitted = true;
      } else {
        base.contentOmitted = false;
      }
      uResults.push(base);
    }
  };
  const uWorkers: Promise<void>[] = [];
  for (let w = 0; w < untrackedConcurrency; w++) uWorkers.push(uWorker());
  await Promise.all(uWorkers);
  for (const e of uResults) entries.push(e);

  const tEnd = Date.now();

  // Sort and keep top 5 slowest files for visibility
  slowFiles.sort((a, b) => b.ms - a.ms);
  const topSlow = slowFiles.slice(0, 5);

  const perf: ComputeEntriesPerf = {
    baseRef,
    compareBase,
    tracked: tracked.length,
    untracked: untracked.length,
    entries: entries.length,
    resolveBaseMs: tBaseRef - t0,
    mergeBaseMs: tMergeBase - tBaseRef,
    listTrackedMs: tTracked - tMergeBase,
    listUntrackedMs: tUntracked - tTracked,
    perFileBuildMs,
    numstatMs: timeNumstat,
    patchMs: timePatch,
    readOldMs: timeReadOld,
    readNewMs: timeReadNew,
    readUntrackedMs: timeReadUntracked,
    totalMs: tEnd - tStart,
  };

  serverLogger.info(
    `[Perf][computeEntriesNodeGit] worktree=${worktreePath} baseRef=${baseRef} compareBase=${compareBase} tracked=${tracked.length} untracked=${untracked.length} entries=${entries.length} ` +
      `resolveBaseMs=${perf.resolveBaseMs} mergeBaseMs=${perf.mergeBaseMs} listTrackedMs=${perf.listTrackedMs} listUntrackedMs=${perf.listUntrackedMs} ` +
      `perFileBuildMs=${perf.perFileBuildMs} numstatMs=${perf.numstatMs} patchMs=${perf.patchMs} readOldMs=${perf.readOldMs} readNewMs=${perf.readNewMs} readUntrackedMs=${perf.readUntrackedMs} totalMs=${perf.totalMs}`
  );
  if (topSlow.length > 0) {
    serverLogger.info(
      `[Perf][computeEntriesNodeGit.slowest] ${JSON.stringify(topSlow)}`
    );
  }

  if (opts.perfOut) {
    opts.perfOut.baseRef = perf.baseRef;
    opts.perfOut.compareBase = perf.compareBase;
    opts.perfOut.tracked = perf.tracked;
    opts.perfOut.untracked = perf.untracked;
    opts.perfOut.entries = perf.entries;
    opts.perfOut.resolveBaseMs = perf.resolveBaseMs;
    opts.perfOut.mergeBaseMs = perf.mergeBaseMs;
    opts.perfOut.listTrackedMs = perf.listTrackedMs;
    opts.perfOut.listUntrackedMs = perf.listUntrackedMs;
    opts.perfOut.perFileBuildMs = perf.perFileBuildMs;
    opts.perfOut.numstatMs = perf.numstatMs;
    opts.perfOut.patchMs = perf.patchMs;
    opts.perfOut.readOldMs = perf.readOldMs;
    opts.perfOut.readNewMs = perf.readNewMs;
    opts.perfOut.readUntrackedMs = perf.readUntrackedMs;
    opts.perfOut.totalMs = perf.totalMs;
    opts.perfOut.slowest = topSlow;
  }

  return entries;
}

export async function computeEntriesBetweenRefs(opts: {
  repoPath: string; // path to a local git repo (origin)
  ref1: string;
  ref2: string;
  includeContents?: boolean;
  maxBytes?: number;
}): Promise<ReplaceDiffEntry[]> {
  const {
    repoPath,
    ref1,
    ref2,
    includeContents = true,
    maxBytes = 950 * 1024,
  } = opts;
  // Use --find-renames and NUL delimiter for reliable parsing
  const { stdout: nsOut } = await execAsync(
    `git diff --name-status -z --find-renames ${ref1}..${ref2}`,
    { cwd: repoPath }
  );
  const tokens = nsOut.split("\0").filter(Boolean);
  type Item = { status: DiffStatus; filePath: string; oldPath?: string };
  const items: Item[] = [];
  let i = 0;
  while (i < tokens.length) {
    const code = tokens[i++]!;
    if (!code) break;
    if (code.startsWith("R") || code.startsWith("C")) {
      const oldPath = tokens[i++] || "";
      const newPath = tokens[i++] || "";
      if (!oldPath || !newPath) continue;
      items.push({ status: "renamed", filePath: newPath, oldPath });
    } else {
      const fp = tokens[i++] || "";
      if (!fp) continue;
      const status: DiffStatus =
        code === "A" ? "added" : code === "D" ? "deleted" : "modified";
      items.push({ status, filePath: fp });
    }
  }

  const results = await Promise.all(
    items.map(async (it) => {
      let additions = 0;
      let deletions = 0;
      let isBinary = false;
      let patchText: string | undefined;
      let oldContent: string | undefined;
      let newContent: string | undefined;

      try {
        const { stdout: ns } = await execAsync(
          `git diff --numstat ${ref1}..${ref2} -- "${escapePath(it.filePath)}"`,
          { cwd: repoPath }
        );
        const line = ns
          .split("\n")
          .find((l) => l.trim().endsWith(`\t${it.filePath}`));
        if (line) {
          const [a, d] = line.split("\t");
          isBinary = a === "-" || d === "-";
          additions = isBinary ? 0 : parseInt(a || "0", 10);
          deletions = isBinary ? 0 : parseInt(d || "0", 10);
        }

        if (!isBinary && includeContents) {
          if (it.status !== "added") {
            try {
              const { stdout } = await execAsync(
                `git show ${ref1}:"${escapePath(it.oldPath ?? it.filePath)}"`,
                { cwd: repoPath, maxBuffer: 10 * 1024 * 1024 }
              );
              oldContent = stdout;
            } catch {
              oldContent = "";
            }
          } else {
            oldContent = "";
          }
          if (it.status !== "deleted") {
            try {
              const { stdout } = await execAsync(
                `git show ${ref2}:"${escapePath(it.filePath)}"`,
                { cwd: repoPath, maxBuffer: 10 * 1024 * 1024 }
              );
              newContent = stdout;
            } catch {
              newContent = "";
            }
          } else {
            newContent = "";
          }

          const { stdout: pOut } = await execAsync(
            `git diff --patch --binary --no-color ${ref1}..${ref2} -- "${escapePath(it.filePath)}"`,
            { cwd: repoPath, maxBuffer: 10 * 1024 * 1024 }
          );
          patchText = pOut || undefined;
        }
      } catch {
        // fallthrough
      }

      const patchSize =
        !isBinary && patchText ? Buffer.byteLength(patchText, "utf8") : 0;
      const oldSize = oldContent ? Buffer.byteLength(oldContent, "utf8") : 0;
      const newSize = newContent ? Buffer.byteLength(newContent, "utf8") : 0;
      const totalApprox = patchSize + oldSize + newSize;

      const base: ReplaceDiffEntry = {
        filePath: it.filePath,
        oldPath: it.oldPath,
        status: it.status,
        additions,
        deletions,
        isBinary,
        patchSize,
        oldSize,
        newSize,
      };

      if (!isBinary && includeContents) {
        if (totalApprox <= maxBytes) {
          base.patch = patchText;
          base.oldContent = oldContent;
          base.newContent = newContent;
          base.contentOmitted = false;
        } else {
          base.patch = patchSize < maxBytes ? patchText : undefined;
          base.contentOmitted = true;
        }
      } else {
        base.contentOmitted = false;
      }

      if (
        base.status === "modified" &&
        !base.isBinary &&
        base.additions === 0 &&
        base.deletions === 0 &&
        (!base.patch || base.patch.trim() === "")
      ) {
        return null;
      }

      return base;
    })
  );

  return results.filter((e): e is ReplaceDiffEntry => !!e);
}

const defaultBranchCache = new Map<string, { value: string; ts: number }>();
const DEFAULT_BRANCH_TTL_MS = 30_000;

async function resolvePrimaryBaseRef(cwd: string): Promise<string> {
  // Prefer the repository default branch (e.g., origin/main)
  try {
    const now = Date.now();
    const cached = defaultBranchCache.get(cwd);
    let defaultBranch: string | null = null;
    if (cached && now - cached.ts < DEFAULT_BRANCH_TTL_MS) {
      defaultBranch = cached.value;
    } else {
      const repoMgr = RepositoryManager.getInstance();
      defaultBranch = await repoMgr.getDefaultBranch(cwd);
      defaultBranchCache.set(cwd, { value: defaultBranch, ts: now });
    }
    if (defaultBranch) return `origin/${defaultBranch}`;
  } catch (err) {
    serverLogger.debug(
      `[Diffs] Could not detect default branch for ${cwd}: ${String(
        (err as Error)?.message || err
      )}`
    );
  }
  // Fallback: use upstream only when default branch detection fails
  try {
    const { stdout } = await execAsync(
      "git rev-parse --abbrev-ref --symbolic-full-name @{u}",
      { cwd }
    );
    if (stdout.trim()) return "@{upstream}";
  } catch (err) {
    serverLogger.debug(
      `[Diffs] No upstream for ${cwd}: ${String((err as Error)?.message || err)}`
    );
  }
  // Final fallback
  return "origin/main";
}

async function resolveMergeBaseWithDeepen(
  cwd: string,
  baseRef: string
): Promise<string> {
  // Try merge-base to emulate GitHub PR compare; shallow clones may need deepen
  const tryMergeBase = async (): Promise<string | null> => {
    try {
      const { stdout } = await execAsync(`git merge-base ${baseRef} HEAD`, {
        cwd,
      });
      const mb = stdout.trim();
      return mb || null;
    } catch {
      return null;
    }
  };

  let mb = await tryMergeBase();
  if (mb) return mb;

  // Determine branch name to deepen if possible
  let remoteBranch = "";
  try {
    if (baseRef === "@{upstream}") {
      const { stdout } = await execAsync(
        "git rev-parse --abbrev-ref --symbolic-full-name @{u}",
        { cwd }
      );
      remoteBranch = stdout.trim(); // e.g., origin/main
    } else {
      remoteBranch = baseRef; // likely origin/<branch>
    }
  } catch {
    remoteBranch = baseRef;
  }

  const m = remoteBranch.match(/^origin\/(.+)$/);
  const branchName = m ? m[1] : "";

  // Attempt to deepen history progressively to locate a merge-base
  const depths = [50, 200, 1000];
  for (const depth of depths) {
    try {
      if (branchName) {
        await execAsync(`git fetch --deepen=${depth} origin ${branchName}`, {
          cwd,
        });
      } else {
        await execAsync(`git fetch --deepen=${depth} origin`, { cwd });
      }
    } catch {
      // ignore fetch errors; attempt merge-base anyway
    }
    mb = await tryMergeBase();
    if (mb) return mb;
  }

  // Fallback to baseRef directly when merge-base cannot be resolved
  return baseRef;
}

async function getTrackedChanges(
  cwd: string,
  baseRef: string
): Promise<
  {
    status: DiffStatus;
    filePath: string;
    oldPath?: string;
  }[]
> {
  // NUL-delimited; for renames, format is: Rxxx<TAB>old<NUL>new<NUL>
  // for normal entries: M|A|D<TAB>path<NUL>
  const { stdout } = await execAsync(
    `git diff --name-status -z --find-renames ${baseRef}`,
    { cwd }
  );
  const tokens = stdout.split("\0").filter(Boolean);
  const items: { status: DiffStatus; filePath: string; oldPath?: string }[] =
    [];
  let i = 0;
  while (i < tokens.length) {
    const code = tokens[i++]!; // e.g., 'M', 'A', 'D', 'R100'
    if (!code) break;
    if (code.startsWith("R") || code.startsWith("C")) {
      const oldPath = tokens[i++] || "";
      const newPath = tokens[i++] || "";
      if (!oldPath || !newPath) continue;
      items.push({ status: "renamed", filePath: newPath, oldPath });
    } else {
      const fp = tokens[i++] || "";
      if (!fp) continue;
      const status: DiffStatus =
        code === "A" ? "added" : code === "D" ? "deleted" : "modified";
      items.push({ status, filePath: fp });
    }
  }
  return items;
}

async function getUntrackedFiles(cwd: string): Promise<string[]> {
  try {
    const { stdout } = await execAsync(
      "git ls-files --others --exclude-standard -z",
      { cwd }
    );
    return stdout.split("\0").filter(Boolean);
  } catch {
    return [];
  }
}

async function getPatchMap(
  cwd: string,
  baseRef: string
): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  try {
    const { stdout } = await execAsync(
      `git diff --patch --binary --no-color --find-renames ${baseRef}`,
      { cwd, maxBuffer: 50 * 1024 * 1024 }
    );
    // Split into blocks starting at 'diff --git'
    const lines = stdout.split("\n");
    let current: string[] = [];
    let currentPlus: string | null = null;
    let currentMinus: string | null = null;
    const flush = (): void => {
      if (current.length === 0) return;
      const block = current.join("\n");
      let key: string | null = null;
      if (currentPlus && currentPlus !== "/dev/null") {
        key = currentPlus.replace(/^b\//, "");
      } else if (currentMinus && currentMinus !== "/dev/null") {
        key = currentMinus.replace(/^a\//, "");
      }
      if (key) {
        map.set(key, block);
      }
      current = [];
      currentPlus = null;
      currentMinus = null;
    };
    for (const line of lines) {
      if (line.startsWith("diff --git ")) {
        flush();
        current.push(line);
        continue;
      }
      current.push(line);
      if (line.startsWith("+++ ")) {
        const p = line.slice(4).trim();
        currentPlus = p.startsWith("b/") ? p.slice(2) : p;
      } else if (line.startsWith("--- ")) {
        const p = line.slice(4).trim();
        currentMinus = p.startsWith("a/") ? p.slice(2) : p;
      }
    }
    flush();
  } catch {
    // ignore; return empty map
  }
  return map;
}

async function gitShowFilesBatch(
  cwd: string,
  baseRef: string,
  files: string[]
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (files.length === 0) return out;
  return new Promise<Map<string, string>>((resolve) => {
    const child = spawn("git", ["cat-file", "--batch"], { cwd });
    const pending = [...files];
    let buf = Buffer.alloc(0);
    let idx = 0;

    const tryProcess = (): void => {
      while (true) {
        const nl = buf.indexOf(0x0a); // '\n'
        if (nl === -1) return;
        const header = buf.slice(0, nl).toString("ascii").trim();
        if (header.endsWith(" missing")) {
          // Advance past header only; increment index, no content follows
          buf = buf.slice(nl + 1);
          idx++;
          continue;
        }
        const parts = header.split(" ");
        if (parts.length < 3) return; // need more data
        const size = parseInt(parts[2] || "0", 10);
        const need = nl + 1 + size + 1; // header + content + trailing \n
        if (buf.length < need) return; // wait for more

        const content = buf.slice(nl + 1, nl + 1 + size);
        // Move buffer forward past header+content+newline
        buf = buf.slice(need);

        const path = pending[idx++];
        if (path) {
          out.set(path, content.toString("utf8"));
        }
      }
    };

    child.stdout.on("data", (chunk: Buffer) => {
      buf = Buffer.concat([buf, chunk]);
      tryProcess();
    });
    child.stderr.on("data", () => {
      // ignore errors for missing paths; will resolve with what we have
    });
    child.on("close", () => resolve(out));
    child.on("error", () => resolve(out));

    // Write requests
    for (const f of pending) {
      // cat-file --batch takes an object name; use treeish:path without quotes
      child.stdin.write(`${baseRef}:${f}\n`);
    }
    child.stdin.end();
  });
}

async function getNumstatMap(
  cwd: string,
  baseRef: string
): Promise<
  Map<string, { additions: number; deletions: number; isBinary: boolean }>
> {
  const out = new Map<
    string,
    { additions: number; deletions: number; isBinary: boolean }
  >();
  try {
    const { stdout } = await execAsync(
      `git diff --numstat --find-renames ${baseRef}`,
      { cwd }
    );
    const lines = stdout.split("\n");
    for (const line of lines) {
      if (!line.trim()) continue;
      const parts = line.split("\t");
      if (parts.length < 3) continue;
      const a = parts[0] || "0";
      const d = parts[1] || "0";
      const fp = parts.slice(2).join("\t");
      const isBinary = a === "-" || d === "-";
      const additions = isBinary ? 0 : parseInt(a || "0", 10);
      const deletions = isBinary ? 0 : parseInt(d || "0", 10);
      out.set(fp, { additions, deletions, isBinary });
    }
  } catch {
    // fall back to empty map; per-file lookups may default to zeros
  }
  return out;
}

function escapePath(p: string): string {
  return p.replace(/"/g, '\\"');
}
