// One-time open codes (cx-e3l1). `cmux open` takes its URL in argv, which
// other local processes can read, so cmux-chat never puts the launch token
// there: it asks the server (over curl's stdin) for a code and opens
// `/o/<code>`, which answers with a redirect to the tokened page. A code is
// used once (spent by the first try, also a refused one), expires in 60 s,
// is kept only as a SHA-256 hash, and at most 16 are live. Its target is a
// page route of this server only, so `/o/` is never an open redirect.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

const TTL_MS = 60_000;
const CAP = 16;

// The page routes the browser surface opens: the composer, a chat, a
// terminal's chat view, the gallery. Ids match the server's own forms.
const PAGE = /^\/(?:s\/[A-Za-z0-9_-]{1,64}|terminal\/[0-9A-Fa-f-]{8,64}|gallery)?\/?$/;
const QUERY = /^(?:\?[A-Za-z0-9_=&.-]*)?$/;

type Entry = { hash: Buffer; target: string; expires: number };

function hash(code: string): Buffer {
  return createHash("sha256").update(code, "utf8").digest();
}

/// `path` as a redirect target (pathname plus query), or null when it is not
/// exactly one of this server's page routes.
export function pageTarget(path: string): string | null {
  const at = path.indexOf("?");
  const pathname = at < 0 ? path : path.slice(0, at);
  const query = at < 0 ? "" : path.slice(at);
  return PAGE.test(pathname) && QUERY.test(query) ? pathname + query : null;
}

export class OpenCodes {
  private entries: Entry[] = [];

  constructor(private readonly now: () => number = Date.now) {}

  get size(): number {
    return this.entries.length;
  }

  /// A new code for `path`, or null when `path` is not a page route.
  issue(path: string): string | null {
    const target = pageTarget(path);
    if (target === null) return null;
    this.prune();
    while (this.entries.length >= CAP) this.entries.shift();
    const code = randomBytes(32).toString("base64url");
    this.entries.push({ hash: hash(code), target, expires: this.now() + TTL_MS });
    return code;
  }

  /// The target of `code`, once. Every entry is compared (constant time per
  /// entry, the same work for a hit or a miss); a matched entry is removed
  /// whether or not it is still valid.
  redeem(code: string): string | null {
    const presented = hash(code);
    let found: Entry | undefined;
    for (const entry of this.entries) {
      if (timingSafeEqual(entry.hash, presented)) found = entry;
    }
    if (found) this.entries = this.entries.filter((entry) => entry !== found);
    this.prune();
    return found && found.expires > this.now() ? found.target : null;
  }

  storedKeysForTest(): string[] {
    return this.entries.map((entry) => entry.hash.toString("hex"));
  }

  private prune() {
    const now = this.now();
    this.entries = this.entries.filter((entry) => entry.expires > now);
  }
}
