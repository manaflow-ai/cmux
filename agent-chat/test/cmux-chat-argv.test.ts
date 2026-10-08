// cmux-chat never puts the server's token into a child's argv: other local
// users can read argv with ps. Fake curl, cmux and python3 on PATH record the
// argv and stdin of every call; the token may reach them only on stdin.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const TOKEN = "argv-test-token-0123456789abcdefghijklmnopqrstuv";
const PORT = "47391";
let dir = "";
let bin = "";

// Each fake logs one JSON line {tool, argv, stdin} and answers like the real
// tool would for cmux-chat. The real python3 still runs (after logging).
function fake(tool: string, answer: string): string {
  return `#!/bin/bash
stdin=""
if [ ! -t 0 ]; then stdin="$(cat)"; fi
/usr/bin/python3 -c 'import json,sys; print(json.dumps({"tool": sys.argv[1], "argv": sys.argv[2:-1], "stdin": sys.argv[-1]}))' \\
  ${JSON.stringify(tool)} "$@" "$stdin" >> "$CHAT_ARGV_LOG"
${answer}
`;
}

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), "cmux-chat-argv-"));
  bin = join(dir, "bin");
  await mkdir(bin);
  await mkdir(join(dir, ".cmux", "agent-chat"), { recursive: true });
  await writeFile(join(dir, ".cmux", "agent-chat", `token-${PORT}`), `${TOKEN}\n`, { mode: 0o600 });
  await writeFile(join(bin, "curl"), fake("curl", `case "$stdin" in
  *"/api/sessions"*) printf '%s' '{"url":"http://127.0.0.1:${PORT}/${TOKEN}/s/abc"}' ;;
esac
exit 0`));
  await writeFile(join(bin, "cmux"), fake("cmux", "echo OK"));
  // The real python3 gets the same stdin the fake read.
  await writeFile(join(bin, "python3"), fake("python3", `printf '%s' "$stdin" | /usr/bin/python3 "$@"`));
  for (const tool of ["curl", "cmux", "python3"]) await chmod(join(bin, tool), 0o755);
});

afterAll(async () => {
  if (dir) await rm(dir, { recursive: true, force: true });
});

type Call = { tool: string; argv: string[]; stdin: string };

async function run(args: string[]): Promise<{ calls: Call[]; stdout: string; code: number }> {
  const log = join(dir, `calls-${crypto.randomUUID()}.jsonl`);
  await writeFile(log, "");
  const proc = Bun.spawn(["/bin/bash", join(import.meta.dir, "..", "cmux-chat"), ...args], {
    cwd: dir,
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: dir, CMUX_AGENT_UI_PORT: PORT, CHAT_ARGV_LOG: log, CMUX_WORKSPACE_ID: "ws-1" },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) console.error(stderr);
  const calls = (await readFile(log, "utf8")).trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as Call);
  return { calls, stdout, code };
}

for (const [mode, args] of [
  ["a new tab", []],
  ["a chat started with a prompt", ["fix", "the", "tests"]],
  ["a split", ["--split"]],
  ["a terminal chat view", ["--terminal", "--surface", "surface-1"]],
] as const) {
  test(`${mode}: the token is in no argv and the opened URL still carries it`, async () => {
    const { calls, stdout, code } = await run([...args]);
    expect(code).toBe(0);
    expect(calls.length).toBeGreaterThan(0);
    for (const call of calls) {
      expect({ tool: call.tool, argv: call.argv.join(" ").includes(TOKEN) }).toEqual({ tool: call.tool, argv: false });
    }
    const opens = calls.filter((call) => call.tool === "cmux");
    expect(opens.length).toBe(1);
    expect(opens[0].stdin).toContain(`/${TOKEN}/`);
    expect(stdout.trim()).toContain(`/${TOKEN}/`);
  });
}
