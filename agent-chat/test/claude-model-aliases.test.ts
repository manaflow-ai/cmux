// cx-miuo: only Claude Code says what its aliases run (plans/cmux-next/model-catalog.md,
// rule 3). Claude Code 2.1.295 reports `opus` as Opus 5.5; the sidecar must offer that
// choice as `opus`, not fold it into an older catalog release (claude-opus-4-8) and hide it.
// Checked against a real server process with a stand-in `claude` on PATH.
import { afterAll, expect, test } from "bun:test";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const LISTED = {
  type: "control_response",
  response: {
    subtype: "success",
    request_id: "cmux-list-options",
    response: {
      models: [
        { value: "default", displayName: "Default (recommended)" },
        { value: "opus", displayName: "Opus 5.5", description: "Opus 5.5 for complex work" },
        { value: "sonnet", displayName: "Sonnet 5.5" },
      ],
    },
  },
};

const FAKE_CLAUDE = `#!/bin/sh
if [ "$1" = "--version" ]; then echo "2.1.295 (Claude Code)"; exit 0; fi
while IFS= read -r line; do
  case "$line" in
    *cmux-list-options*) printf '%s\\n' '${JSON.stringify(LISTED)}' ;;
  esac
done
`;

const dirs: string[] = [];
const procs: ReturnType<typeof Bun.spawn>[] = [];
afterAll(async () => {
  for (const proc of procs) proc.kill();
  for (const dir of dirs) await rm(dir, { recursive: true, force: true });
});

async function waitForFile(path: string): Promise<string> {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const text = await readFile(path, "utf8").catch(() => "");
    if (text.trim()) return text;
    await Bun.sleep(50);
  }
  throw new Error(`${path} was not written`);
}

test("a Claude Code alias is offered as itself, never as an older catalog release", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agent-chat-aliases-"));
  dirs.push(dir);
  const bin = join(dir, "bin");
  await Bun.write(join(bin, "claude"), FAKE_CLAUDE);
  await chmod(join(bin, "claude"), 0o755);
  const env = {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: dir,
    CMUX_AGENT_CHAT_PORT: "0",
    CMUX_AGENT_CHAT_STATE_FILE: join(dir, "state.json"),
    CMUX_AGENT_CHAT_TOKEN_FILE: join(dir, "token"),
    // No catalog server: the sidecar answers from its built-in Claude list.
    CMUX_AGENT_MODELS_URL: "http://127.0.0.1:9/agent-models",
  };
  const log = Bun.file(join(dir, "server.log"));
  const proc = Bun.spawn([process.execPath, "server.ts"], { cwd: join(import.meta.dir, ".."), env, stdio: ["ignore", log, log] });
  procs.push(proc);
  const state = JSON.parse(await waitForFile(env.CMUX_AGENT_CHAT_STATE_FILE));
  const token = (await waitForFile(env.CMUX_AGENT_CHAT_TOKEN_FILE)).trim();

  const ws = new WebSocket(`ws://127.0.0.1:${state.port}/${token}/ws`);
  const reply = await new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("no options-list")), 30_000);
    ws.onopen = () => ws.send(JSON.stringify({ op: "list-options", provider: "claude", cwd: dir }));
    ws.onmessage = (event) => {
      const msg = JSON.parse(String(event.data));
      if (msg.kind === "options-list" && msg.provider === "claude") { clearTimeout(timer); resolve(msg); }
      if (msg.kind === "error") { clearTimeout(timer); reject(new Error(String(msg.message))); }
    };
    ws.onerror = () => { clearTimeout(timer); reject(new Error("websocket error")); };
  }).finally(() => ws.close());

  const model = (reply.options as { id: string; choices?: { value: string; label: string }[] }[]).find((option) => option.id === "model");
  const values = (model?.choices ?? []).map((choice) => choice.value);
  expect(values).toContain("opus");
  expect(model?.choices?.find((choice) => choice.value === "opus")?.label).toBe("Opus 5.5");
});
