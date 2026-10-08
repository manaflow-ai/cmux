// The sidecar's localhost listener rule (plans/cmux-next/identity.md
// section 4, decision D5): a per-launch token is mandatory on every route
// and the WebSocket upgrade, it never comes from argv or the environment,
// and a foreign Origin or a rebinding Host is refused everywhere.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { closeSync, openSync } from "node:fs";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SERVER = join(import.meta.dir, "..", "server.ts");

type Launch = { proc: ReturnType<typeof Bun.spawn>; port: number; token: string; dir: string; statePath: string };

async function waitForState(statePath: string, proc: ReturnType<typeof Bun.spawn>): Promise<any> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) throw new Error(`server exited ${proc.exitCode}`);
    try {
      return JSON.parse(await readFile(statePath, "utf8"));
    } catch {
      await Bun.sleep(50);
    }
  }
  throw new Error("no state file within 30 s");
}

function baseEnv(dir: string): Record<string, string> {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: dir,
    CMUX_AGENT_CHAT_PORT: "0",
    CMUX_AGENT_CHAT_STATE_FILE: join(dir, "state", "agent-chat.json"),
  };
}

async function launch(extraArgs: string[] = [], stdio: any = ["ignore", "ignore", "inherit"]): Promise<Launch> {
  const dir = await mkdtemp(join(tmpdir(), "agent-chat-auth-"));
  const env = baseEnv(dir);
  const proc = Bun.spawn([process.execPath, SERVER, ...extraArgs], { env, stdio });
  const state = await waitForState(env.CMUX_AGENT_CHAT_STATE_FILE, proc);
  return { proc, port: state.port, token: state.token, dir, statePath: env.CMUX_AGENT_CHAT_STATE_FILE };
}

async function stop(l: Launch) {
  l.proc.kill();
  await l.proc.exited;
  await rm(l.dir, { recursive: true, force: true });
}

/// One raw HTTP request (fetch would set Host and Origin itself).
async function raw(port: number, path: string, headers: Record<string, string>): Promise<number> {
  const lines = [`GET ${path} HTTP/1.1`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`), "Connection: close", "", ""];
  return await new Promise<number>((resolve, reject) => {
    let data = "";
    Bun.connect({
      hostname: "127.0.0.1",
      port,
      socket: {
        open(s) {
          s.write(lines.join("\r\n"));
        },
        data(_s, chunk) {
          data += new TextDecoder().decode(chunk);
          const m = data.match(/^HTTP\/1\.1 (\d{3})/);
          if (m) resolve(Number(m[1]));
        },
        close() {
          const m = data.match(/^HTTP\/1\.1 (\d{3})/);
          m ? resolve(Number(m[1])) : reject(new Error(`no status: ${JSON.stringify(data)}`));
        },
        error(_s, e) {
          reject(e);
        },
      },
    }).catch(reject);
  });
}

function upgradeHeaders(host: string, origin?: string): Record<string, string> {
  return {
    Host: host,
    ...(origin ? { Origin: origin } : {}),
    Upgrade: "websocket",
    Connection: "Upgrade",
    "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version": "13",
  };
}

describe("agent-chat launch token and listener rule", () => {
  let l: Launch;
  beforeAll(async () => {
    l = await launch();
  }, 40_000);
  afterAll(async () => {
    await stop(l);
  });

  test("the launch makes a token and reports it only in an owner-only state file", async () => {
    expect(typeof l.token).toBe("string");
    expect(l.token.length).toBeGreaterThanOrEqual(32);
    expect((await stat(l.statePath)).mode & 0o777).toBe(0o600);
    expect((await stat(join(l.dir, "state"))).mode & 0o777).toBe(0o700);
  });

  test("a missing or wrong token is refused on pages, assets, APIs and the upgrade", async () => {
    const host = `127.0.0.1:${l.port}`;
    for (const path of ["/", "/app.js", "/api/sessions", "/api/theme", "/s/x"]) {
      expect(await raw(l.port, path, { Host: host })).toBe(404);
      expect(await raw(l.port, `/wrong-token${path}`, { Host: host })).toBe(404);
      expect(await raw(l.port, `/${l.token.slice(0, -1)}x${path}`, { Host: host })).toBe(404);
    }
    expect(await raw(l.port, "/ws", upgradeHeaders(host))).toBe(404);
    expect(await raw(l.port, "/wrong/ws", upgradeHeaders(host))).toBe(404);
    expect(await raw(l.port, `/${l.token}/`, { Host: host })).toBe(200);
    expect(await raw(l.port, `/${l.token}/api/sessions`, { Host: host })).toBe(200);
  });

  test("a foreign or null Origin is refused on every route, also with the token", async () => {
    const host = `127.0.0.1:${l.port}`;
    for (const origin of ["https://evil.example", "null", `http://127.0.0.1:${l.port + 1}`]) {
      for (const path of ["/", "/app.js", "/api/sessions", "/api/theme", "/healthz"]) {
        const p = path === "/healthz" ? path : `/${l.token}${path}`;
        expect(await raw(l.port, p, { Host: host, Origin: origin })).toBe(403);
      }
      expect(await raw(l.port, `/${l.token}/ws`, upgradeHeaders(host, origin))).toBe(403);
    }
    // The page's own origin is accepted.
    expect(await raw(l.port, `/${l.token}/api/sessions`, { Host: host, Origin: `http://${host}` })).toBe(200);
  });

  test("a rebinding Host is refused on every route, also with the token", async () => {
    for (const host of ["evil.example", `evil.example:${l.port}`, "127.0.0.1.nip.io"]) {
      for (const path of ["/healthz", `/${l.token}/`, `/${l.token}/api/sessions`]) {
        expect(await raw(l.port, path, { Host: host })).toBe(403);
      }
      expect(await raw(l.port, `/${l.token}/ws`, upgradeHeaders(host))).toBe(403);
    }
  });

  test("path and Host tricks never reach a handler without the token", async () => {
    const host = `127.0.0.1:${l.port}`;
    for (const path of ["//app.js", `/x/..%2F${l.token}/`, `/%2F${l.token}/`, `/${l.token}%2Fapi/sessions`, "/../api/sessions"]) {
      expect(await raw(l.port, path, { Host: host })).toBe(404);
    }
    for (const badHost of [`a@127.0.0.1:${l.port}`, "127.1", "localhost.", `127.0.0.1:${l.port}, evil.example`]) {
      expect(await raw(l.port, `/${l.token}/`, { Host: badHost })).toBe(403);
    }
    // No Host header at all is never served.
    expect(await raw(l.port, `/${l.token}/`, {})).not.toBe(200);
  });

  test("the WebSocket opens only under the token", async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${l.port}/${l.token}/ws`);
    const hello = await new Promise<any>((resolve, reject) => {
      ws.onmessage = (e) => resolve(JSON.parse(String(e.data)));
      ws.onerror = () => reject(new Error("ws error"));
    });
    expect(hello.kind).toBe("hello");
    ws.close();
  });
});

describe("agent-chat token sources", () => {
  test("a token in argv or the environment is refused at start", async () => {
    const dir = await mkdtemp(join(tmpdir(), "agent-chat-auth-"));
    try {
      for (const [args, extraEnv] of [
        [["--token", "abcdefabcdefabcdefabcdefabcdefab"], {}],
        [[], { CMUX_AGENT_CHAT_TOKEN: "abcdefabcdefabcdefabcdefabcdefab" }],
      ] as const) {
        const proc = Bun.spawn([process.execPath, SERVER, ...args], {
          env: { ...baseEnv(dir), ...extraEnv },
          stdio: ["ignore", "ignore", "pipe"],
        });
        const code = await Promise.race([proc.exited, Bun.sleep(20_000).then(() => "running")]);
        if (code === "running") proc.kill();
        expect(code).not.toBe("running");
        expect(code).not.toBe(0);
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }, 60_000);

  test("a launcher may hand its token over an inherited pipe (--token-fd)", async () => {
    const chosen = "f".repeat(64);
    const dir = await mkdtemp(join(tmpdir(), "agent-chat-auth-"));
    const env = baseEnv(dir);
    // An inherited descriptor the launcher opened (a pipe in cmux-chat).
    await Bun.write(join(dir, "token"), `${chosen}\n`);
    const fd = openSync(join(dir, "token"), "r");
    const proc = Bun.spawn([process.execPath, SERVER, "--token-fd", "3"], {
      env,
      stdio: ["ignore", "ignore", "inherit", fd],
    });
    closeSync(fd);
    try {
      const state = await waitForState(env.CMUX_AGENT_CHAT_STATE_FILE, proc);
      expect(state.token).toBe(chosen);
      expect(await raw(state.port, `/${chosen}/`, { Host: `127.0.0.1:${state.port}` })).toBe(200);
    } finally {
      proc.kill();
      await proc.exited;
      await rm(dir, { recursive: true, force: true });
    }
  }, 40_000);
});
