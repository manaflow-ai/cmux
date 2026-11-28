// cmux-chat never puts the server's token into a child's argv: other local
// processes can read argv. Only fake curl, cmux and python3 (plus links to
// the few system tools the script runs) are on PATH; each fake records its
// argv and stdin. The token may reach curl only in its stdin config, and
// cmux gets a one-time code URL (/o/<code>), never the tokened page.
// (Reused from the other cx-e3l1 lane's 079e89b22d1, reworked for codes.)
import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const TOKEN = "argv-test-token-0123456789abcdefghijklmnopqrstuv";
const CODE = "one-time-code-abcdefghijklmnopqrstuvwxyz0123456";
const PORT = "47391";
let dir = "";
let bin = "";

// Each fake logs one JSON line {tool, argv, stdin} and answers like the real
// tool would for cmux-chat. The real python3 still runs (after logging).
function fake(tool: string, answer: string): string {
  return `#!/bin/bash
stdin=""
if [ ! -t 0 ]; then stdin="$(/bin/cat)"; fi
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
  *"/api/sessions"*) printf '%s' '{"url":"http://127.0.0.1:${PORT}/${TOKEN}/s/abc12345"}' ;;
  *"/api/open-code"*) printf '%s' '{"url":"http://127.0.0.1:${PORT}/o/${CODE}"}' ;;
esac
exit 0`));
  await writeFile(join(bin, "cmux"), fake("cmux", "echo OK"));
  // The real python3 gets the same stdin the fake read.
  await writeFile(join(bin, "python3"), fake("python3", `printf '%s' "$stdin" | /usr/bin/python3 "$@"`));
  for (const tool of ["curl", "cmux", "python3"]) await chmod(join(bin, tool), 0o755);
  for (const tool of ["/usr/bin/seq", "/usr/bin/head", "/bin/sleep", "/bin/cat", "/usr/bin/dirname", "/usr/bin/readlink", "/usr/bin/sed"]) {
    await symlink(tool, join(bin, tool.split("/").pop()!));
  }
});

afterAll(async () => {
  if (dir) await rm(dir, { recursive: true, force: true });
});

type Call = { tool: string; argv: string[]; stdin: string };

async function run(args: string[]): Promise<{ calls: Call[]; stdout: string; code: number; stderr: string }> {
  const log = join(dir, `calls-${crypto.randomUUID()}.jsonl`);
  await writeFile(log, "");
  const proc = Bun.spawn(["/bin/bash", join(import.meta.dir, "..", "cmux-chat"), ...args], {
    cwd: dir,
    env: { PATH: bin, HOME: dir, CMUX_AGENT_UI_PORT: PORT, CHAT_ARGV_LOG: log, CMUX_WORKSPACE_ID: "ws-1" },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  const calls = (await readFile(log, "utf8")).trim().split("\n").filter(Boolean).map((line) => JSON.parse(line) as Call);
  return { calls, stdout, code, stderr };
}

for (const [mode, args, page] of [
  ["a new chat", [], "/"],
  ["a chat started with a prompt", ["fix", "the", "tests"], "/s/abc12345"],
  ["a split", ["--split"], "/?transparent=1"],
  ["a terminal chat view", ["--terminal", "--surface", "0123abcd-ef01"], "/terminal/0123abcd-ef01?transparent=1"],
] as const) {
  test(`${mode}: the token is in no argv, curl reads it on stdin, cmux opens a one-time code`, async () => {
    const { calls, stdout, code, stderr } = await run([...args]);
    expect({ code, stderr }).toEqual({ code: 0, stderr: "" });
    for (const call of calls) {
      expect({ tool: call.tool, argv: call.argv.join(" ").includes(TOKEN) }).toEqual({ tool: call.tool, argv: false });
    }
    // Every curl call that names a tokened URL has it as a config on stdin.
    const tokened = calls.filter((call) => call.tool === "curl" && call.stdin.includes(TOKEN));
    expect(tokened.length).toBeGreaterThan(0);
    for (const call of tokened) {
      expect(call.argv).toContain("-K");
      expect(call.stdin).toMatch(new RegExp(`^url = "http://127\\.0\\.0\\.1:${PORT}/${TOKEN}/`));
    }
    // The code request names this page.
    const codeRequest = calls.find((call) => call.tool === "curl" && call.stdin.includes("/api/open-code"))!;
    const body = codeRequest.argv[codeRequest.argv.indexOf("-d") + 1];
    expect(JSON.parse(body)).toEqual({ path: page });
    // cmux opens only the one-time code URL.
    const opens = calls.filter((call) => call.tool === "cmux");
    expect(opens.map((call) => call.argv)).toEqual([["open", `http://127.0.0.1:${PORT}/o/${CODE}`]]);
    // The tokened URL is printed only with --no-open (asked for explicitly).
    expect(stdout.includes(TOKEN)).toBe(false);
  });
}
