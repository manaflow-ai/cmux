// The sidecar's localhost listener rule (plans/cmux-next/identity.md
// section 4, decision D5). Every request, the WebSocket upgrade and
// /healthz included, needs a loopback Host and either no Origin header (a
// non-browser client) or the listener's own origin. Every route except
// /healthz also needs this launch's token as its first path segment
// (`/<token>/...`): the page is loaded by a browser surface that cannot add
// headers, and its relative asset and WebSocket URLs carry the segment.
//
// The token is made per launch and never read from argv or the
// environment (other local processes can read both). A launcher that wants
// to choose it passes it on an inherited descriptor (`--token-fd N`);
// otherwise the server makes one. Either way it is reported only in the
// owner-only state file.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { closeSync, readFileSync } from "node:fs";

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,256}$/;

export function hasTrustedHost(req: Request): boolean {
  const host = req.headers.get("host") ?? "";
  try {
    const u = new URL(`http://${host}`);
    return u.host === host.toLowerCase() && LOOPBACK_HOSTS.has(u.hostname);
  } catch {
    return false;
  }
}

/// No Origin (curl, Bun's WebSocket client), or exactly this listener's own
/// loopback origin. `null` and every other origin are refused.
export function hasTrustedOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");
  if (origin === null) return true;
  try {
    const u = new URL(origin);
    return u.protocol === "http:" && LOOPBACK_HOSTS.has(u.hostname) && u.host === (req.headers.get("host") ?? "").toLowerCase();
  } catch {
    return false;
  }
}

function digest(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}

/// Constant-time comparison (hashing first hides the length too).
export function tokenMatches(presented: string, expected: string): boolean {
  return expected.length > 0 && timingSafeEqual(digest(presented), digest(expected));
}

/// The route under `/<token>`, or null when the first segment is not this
/// launch's token.
export function stripLaunchToken(url: URL, token: string): URL | null {
  const path = url.pathname;
  const end = path.indexOf("/", 1);
  const segment = path.slice(1, end < 0 ? path.length : end);
  let presented: string;
  try {
    presented = decodeURIComponent(segment);
  } catch {
    return null;
  }
  if (!tokenMatches(presented, token)) return null;
  const next = new URL(url);
  next.pathname = end < 0 ? "/" : path.slice(end);
  return next;
}

/// The listener rule for one request: Host, Origin, then the token. The
/// route without the token, or the refusal to send.
export function gate(req: Request, token: string): URL | Response {
  if (!hasTrustedHost(req) || !hasTrustedOrigin(req)) return new Response("forbidden", { status: 403 });
  const url = new URL(req.url);
  if (url.pathname === "/healthz") return url;
  return stripLaunchToken(url, token) ?? new Response("not found", { status: 404 });
}

/// This launch's token: read from `--token-fd N` when given, else new.
/// Refuses a token in argv or the environment instead of ignoring it, so a
/// launcher that still passes one fails loudly.
export function launchToken(argv: string[], env: Record<string, string | undefined>, readFd = (fd: number) => readFileSync(fd, "utf8")): string {
  if (argv.some((a) => a === "--token" || a.startsWith("--token="))) {
    throw new Error("--token is refused: argv is visible to other processes; pass the token with --token-fd");
  }
  if (env.CMUX_AGENT_CHAT_TOKEN !== undefined) {
    throw new Error("CMUX_AGENT_CHAT_TOKEN is refused: the environment is visible to other processes; pass the token with --token-fd");
  }
  const at = argv.findIndex((a) => a === "--token-fd" || a.startsWith("--token-fd="));
  if (at < 0) return randomBytes(32).toString("hex");
  const raw = argv[at].includes("=") ? argv[at].split("=")[1] : argv[at + 1];
  const fd = Number(raw);
  if (!Number.isInteger(fd) || fd < 3) throw new Error(`--token-fd needs a descriptor number of 3 or more, got ${JSON.stringify(raw)}`);
  // Reads to end of file: the launcher closes its end of the pipe.
  const token = readFd(fd).trim();
  try {
    closeSync(fd);
  } catch {
    // Already closed.
  }
  if (!TOKEN_PATTERN.test(token)) throw new Error("--token-fd: the token must be 32-256 characters of [A-Za-z0-9_-]");
  return token;
}
