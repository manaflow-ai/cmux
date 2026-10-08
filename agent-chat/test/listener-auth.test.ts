// The sidecar's loopback listener rule (D5, cmux-next identity.md section 4),
// checked against a real server process with raw HTTP so the Host and Origin
// headers are exactly what a browser page or a DNS-rebound name would send:
// a token is mandatory (generated per launch when no launcher gives one),
// and every route refuses a foreign Host or Origin.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

type Server = { proc: ReturnType<typeof Bun.spawn>; port: number; dir: string };

async function waitForFile(path: string): Promise<string> {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const text = await readFile(path, "utf8").catch(() => "");
    if (text.trim()) return text;
    await Bun.sleep(50);
  }
  throw new Error(`${path} was not written`);
}

async function startServer(token?: string): Promise<Server> {
  const dir = await mkdtemp(join(tmpdir(), "agent-chat-auth-"));
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: dir,
    CMUX_AGENT_CHAT_PORT: "0",
    CMUX_AGENT_CHAT_STATE_FILE: join(dir, "state.json"),
    CMUX_AGENT_CHAT_TOKEN_FILE: join(dir, "token"),
  };
  if (token) env.CMUX_AGENT_CHAT_TOKEN = token;
  const proc = Bun.spawn([process.execPath, "server.ts"], {
    cwd: join(import.meta.dir, ".."), env, stdout: "ignore", stderr: "ignore",
  });
  const state = JSON.parse(await waitForFile(env.CMUX_AGENT_CHAT_STATE_FILE));
  return { proc, port: state.port, dir };
}

/** One raw request; returns the status code. */
function request(port: number, path: string, headers: Record<string, string>, method = "GET"): Promise<number> {
  return new Promise((resolve, reject) => {
    const socket = connect(port, "127.0.0.1");
    let data = "";
    socket.setEncoding("latin1");
    socket.on("connect", () => {
      const lines = [`${method} ${path} HTTP/1.1`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`), "Connection: close", "", ""];
      socket.write(lines.join("\r\n"));
    });
    socket.on("data", (chunk) => {
      data += chunk;
      const match = /^HTTP\/1\.1 (\d{3})/.exec(data);
      if (match) { resolve(Number(match[1])); socket.destroy(); }
    });
    socket.on("error", reject);
    socket.on("close", () => { if (!/^HTTP\/1\.1 \d{3}/.test(data)) reject(new Error(`no status: ${JSON.stringify(data)}`)); });
  });
}

const upgrade = { Upgrade: "websocket", Connection: "Upgrade", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==" };

let generated: Server;
let token = "";
beforeAll(async () => {
  generated = await startServer();
  token = (await waitForFile(join(generated.dir, "token"))).trim();
}, 30_000);
afterAll(async () => {
  generated?.proc.kill();
  await generated?.proc.exited;
  if (generated) await rm(generated.dir, { recursive: true, force: true });
});

test("a server started without a token generates one and keeps it owner-only", async () => {
  expect(token.length).toBeGreaterThanOrEqual(32);
  expect((await stat(join(generated.dir, "token"))).mode & 0o777).toBe(0o600);
});

test("every route but /healthz needs the token", async () => {
  const host = { Host: `127.0.0.1:${generated.port}` };
  expect(await request(generated.port, "/", host)).toBe(404);
  expect(await request(generated.port, "/api/theme", host)).toBe(404);
  expect(await request(generated.port, "/ws", { ...host, ...upgrade })).toBe(404);
  expect(await request(generated.port, `/${"x".repeat(token.length)}/`, host)).toBe(404);
  expect(await request(generated.port, `/${token.slice(0, -1)}/`, host)).toBe(404);
  expect(await request(generated.port, `/${token}/api/theme`, host)).toBe(200);
  expect(await request(generated.port, "/healthz", host)).toBe(200);
});

test("a foreign or rebound Host is refused on every route", async () => {
  for (const name of ["evil.example", "127.0.0.1.nip.io", `127.0.0.1:${generated.port + 1}`, `evil.example:${generated.port}`]) {
    const host = { Host: name.includes(":") ? name : `${name}:${generated.port}` };
    expect(await request(generated.port, `/${token}/api/theme`, host)).toBe(403);
    expect(await request(generated.port, "/healthz", host)).toBe(403);
  }
});

test("a foreign Origin is refused on every route, also with the token", async () => {
  const host = { Host: `127.0.0.1:${generated.port}` };
  for (const origin of ["https://evil.example", "null", `http://127.0.0.1:${generated.port + 1}`, `http://evil.example:${generated.port}`]) {
    const headers = { ...host, Origin: origin };
    expect(await request(generated.port, `/${token}/`, headers)).toBe(403);
    expect(await request(generated.port, `/${token}/api/theme`, headers)).toBe(403);
    expect(await request(generated.port, `/${token}/app.css`, headers)).toBe(403);
    expect(await request(generated.port, `/${token}/ws`, { ...headers, ...upgrade })).toBe(403);
    expect(await request(generated.port, "/healthz", headers)).toBe(403);
  }
  for (const origin of [`http://127.0.0.1:${generated.port}`, `http://localhost:${generated.port}`]) {
    expect(await request(generated.port, `/${token}/api/theme`, { ...host, Origin: origin })).toBe(200);
  }
});

test("a launcher token is used as given and no token file is written", async () => {
  const given = "launcher-token-0123456789abcdef0123456789abcdef";
  const server = await startServer(given);
  try {
    const host = { Host: `127.0.0.1:${server.port}` };
    expect(await request(server.port, `/${given}/api/theme`, host)).toBe(200);
    expect(await request(server.port, "/api/theme", host)).toBe(404);
    expect(await stat(join(server.dir, "token")).catch(() => null)).toBeNull();
  } finally {
    server.proc.kill();
    await server.proc.exited;
    await rm(server.dir, { recursive: true, force: true });
  }
}, 30_000);
