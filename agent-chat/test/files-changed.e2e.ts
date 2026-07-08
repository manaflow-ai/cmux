import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

const port = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);
const root = join(import.meta.dir, "..", "scratch", "files-changed-e2e");
await rm(root, { recursive: true, force: true });
await mkdir(root, { recursive: true });
await writeFile(join(root, "tracked.txt"), "before\n");

async function run(cmd: string[], cwd = root) {
  const p = Bun.spawn(cmd, { cwd, stdout: "pipe", stderr: "pipe", env: { ...process.env } });
  const code = await p.exited;
  if (code !== 0) throw new Error(`${cmd.join(" ")} failed: ${await new Response(p.stderr).text()}`);
}
await run(["git", "init"]);
await run(["git", "add", "tracked.txt"]);
await run(["git", "-c", "user.email=a@b.c", "-c", "user.name=agent", "commit", "-m", "init"]);

const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
let sessionId = "";
const filesChanged = new Promise<{ path: string }[]>((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("timed out waiting for files-changed")), 120_000);
  ws.onmessage = (ev) => {
    const msg = JSON.parse(String(ev.data));
    if (msg.kind === "session-created") sessionId = msg.session.id;
    if (msg.kind === "event" && msg.evt?.kind === "files-changed") {
      clearTimeout(timeout);
      resolve(msg.evt.files);
    }
    if (msg.kind === "error" && msg.op === "start") {
      clearTimeout(timeout);
      reject(new Error(String(msg.message)));
    }
  };
});
await new Promise<void>((resolve) => { ws.onopen = () => resolve(); });
ws.send(JSON.stringify({
  op: "start",
  provider: "pi",
  cwd: root,
  prompt: "Append the exact line AFTER to tracked.txt and then reply PONG. Do not modify any other files.",
}));
const files = await filesChanged;
if (!files.some((f) => f.path === "tracked.txt")) throw new Error(`tracked.txt missing from files-changed: ${JSON.stringify(files)}`);

const diff = new Promise<string>((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("timed out waiting for file-diff")), 20_000);
  ws.onmessage = (ev) => {
    const msg = JSON.parse(String(ev.data));
    if (msg.kind === "file-diff" && msg.path === "tracked.txt") {
      clearTimeout(timeout);
      resolve(String(msg.diff ?? ""));
    }
  };
});
ws.send(JSON.stringify({ op: "get-file-diff", sessionId, path: "tracked.txt" }));
const text = await diff;
if (!text.includes("tracked.txt") || !/^\+.+/m.test(text)) throw new Error(`unexpected diff: ${text}`);
ws.close();
console.log("files-changed: OK");

export {};
