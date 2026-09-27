// Resolves which transcript a cmux terminal is running, using the hook session
// stores cmux's agent hooks maintain (`~/.cmuxterm/<agent>-hook-sessions.json`).
// Paths only ever come from those stores or the agents' own default layouts, so
// the transcript view cannot be pointed at an arbitrary file.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { TranscriptAgent } from "./adapters/transcript";

export interface TranscriptSource {
  agent: TranscriptAgent;
  sessionId: string;
  path: string;
  cwd?: string;
  surfaceId?: string;
  updatedAt: number;
}

interface HookEntry {
  agent: TranscriptAgent;
  sessionId: string;
  surfaceId?: string;
  cwd?: string;
  transcriptPath?: string;
  updatedAt: number;
}

const AGENTS: TranscriptAgent[] = ["claude", "codex"];
const SESSION_ID = /^[\w-]{8,128}$/;

export interface TranscriptSourceEnv {
  home?: string;
  claudeConfigDir?: string;
  codexHome?: string;
}

function readStore(home: string, agent: TranscriptAgent): { entries: HookEntry[]; activeBySurface: Map<string, string> } {
  const file = join(home, ".cmuxterm", `${agent}-hook-sessions.json`);
  const activeBySurface = new Map<string, string>();
  let root: any;
  try {
    root = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return { entries: [], activeBySurface };
  }
  if (!root || typeof root !== "object") return { entries: [], activeBySurface };
  const active = root.activeSessionsBySurface;
  if (active && typeof active === "object") {
    for (const [surface, value] of Object.entries(active)) {
      const sid = (value as any)?.sessionId;
      if (typeof sid === "string") activeBySurface.set(surface.toUpperCase(), sid);
    }
  }
  const sessions = root.sessions && typeof root.sessions === "object" ? root.sessions : root;
  const entries: HookEntry[] = [];
  for (const [key, value] of Object.entries(sessions)) {
    if (!value || typeof value !== "object" || !SESSION_ID.test(key)) continue;
    const v = value as Record<string, unknown>;
    entries.push({
      agent,
      sessionId: key,
      surfaceId: typeof v.surfaceId === "string" && v.surfaceId ? v.surfaceId.toUpperCase() : undefined,
      cwd: typeof v.cwd === "string" && v.cwd ? v.cwd : undefined,
      transcriptPath: typeof v.transcriptPath === "string" && v.transcriptPath ? v.transcriptPath : undefined,
      updatedAt: typeof v.updatedAt === "number" ? v.updatedAt : 0,
    });
  }
  return { entries, activeBySurface };
}

/** Claude's project directory name for a cwd (`/a/b.c` -> `-a-b-c`). */
export function claudeProjectSlug(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, "-");
}

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

// Codex rollouts live under sessions/YYYY/MM/DD; walk newest days first and
// stop after a bounded number of day directories.
function findCodexRollout(codexHome: string, sessionId: string, maxDays = 120): string | undefined {
  const root = join(codexHome, "sessions");
  const suffix = `-${sessionId}.jsonl`;
  const sortedDirs = (dir: string) => {
    try {
      return readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort().reverse();
    } catch {
      return [];
    }
  };
  let days = 0;
  for (const y of sortedDirs(root)) {
    for (const m of sortedDirs(join(root, y))) {
      for (const d of sortedDirs(join(root, y, m))) {
        if (++days > maxDays) return undefined;
        const dir = join(root, y, m, d);
        let names: string[] = [];
        try {
          names = readdirSync(dir);
        } catch {
          continue;
        }
        const hit = names.find((n) => n.startsWith("rollout-") && n.endsWith(suffix));
        if (hit) return join(dir, hit);
      }
    }
  }
  return undefined;
}

function transcriptPathFor(entry: HookEntry, env: Required<TranscriptSourceEnv>): string | undefined {
  if (entry.transcriptPath && entry.transcriptPath.endsWith(".jsonl") && isFile(entry.transcriptPath)) return entry.transcriptPath;
  if (entry.agent === "claude") {
    if (!entry.cwd) return undefined;
    const path = join(env.claudeConfigDir, "projects", claudeProjectSlug(entry.cwd), `${entry.sessionId}.jsonl`);
    return isFile(path) ? path : undefined;
  }
  return findCodexRollout(env.codexHome, entry.sessionId);
}

function resolvedEnv(env: TranscriptSourceEnv): Required<TranscriptSourceEnv> {
  const home = env.home ?? homedir();
  return {
    home,
    claudeConfigDir: env.claudeConfigDir ?? process.env.CLAUDE_CONFIG_DIR ?? join(home, ".claude"),
    codexHome: env.codexHome ?? process.env.CODEX_HOME ?? join(home, ".codex"),
  };
}

function toSource(entry: HookEntry, env: Required<TranscriptSourceEnv>): TranscriptSource | null {
  const path = transcriptPathFor(entry, env);
  if (!path) return null;
  return { agent: entry.agent, sessionId: entry.sessionId, path, cwd: entry.cwd, surfaceId: entry.surfaceId, updatedAt: entry.updatedAt };
}

/**
 * The transcript for the agent session most recently bound to a terminal
 * surface. A surface's active Claude binding wins over older sessions.
 */
export function resolveSurfaceTranscript(surfaceId: string, env: TranscriptSourceEnv = {}): TranscriptSource | null {
  const resolved = resolvedEnv(env);
  const surface = surfaceId.trim().toUpperCase();
  if (!surface) return null;
  const candidates: { entry: HookEntry; active: boolean }[] = [];
  for (const agent of AGENTS) {
    const store = readStore(resolved.home, agent);
    const activeId = store.activeBySurface.get(surface);
    for (const entry of store.entries) {
      const active = entry.sessionId === activeId;
      if (active || entry.surfaceId === surface) candidates.push({ entry, active });
    }
  }
  candidates.sort((a, b) => Number(b.active) - Number(a.active) || b.entry.updatedAt - a.entry.updatedAt);
  for (const { entry } of candidates) {
    const source = toSource(entry, resolved);
    if (source) return source;
  }
  return null;
}

/** The transcript for a known agent session id, from either hook store. */
export function resolveSessionTranscript(sessionId: string, env: TranscriptSourceEnv = {}): TranscriptSource | null {
  if (!SESSION_ID.test(sessionId)) return null;
  const resolved = resolvedEnv(env);
  for (const agent of AGENTS) {
    const entry = readStore(resolved.home, agent).entries.find((e) => e.sessionId === sessionId);
    if (entry) return toSource(entry, resolved);
  }
  return null;
}
