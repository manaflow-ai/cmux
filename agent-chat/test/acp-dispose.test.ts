import { readFile, rm, writeFile } from "node:fs/promises";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

const promptLog = `${import.meta.dir}/../scratch/acp-dispose-prompts.log`;
const spawnLog = `${import.meta.dir}/../scratch/acp-dispose-spawns.log`;
const promptGate = `${import.meta.dir}/../scratch/acp-dispose-release`;
await Promise.all([
  writeFile(promptLog, ""),
  writeFile(spawnLog, ""),
  rm(promptGate, { force: true }),
]);

const previousPromptLog = process.env.FAKE_ACP_PROMPT_LOG;
const previousModelLog = process.env.FAKE_ACP_MODEL_LOG;
const previousPromptGate = process.env.FAKE_ACP_PROMPT_GATE;
process.env.FAKE_ACP_PROMPT_LOG = promptLog;
process.env.FAKE_ACP_MODEL_LOG = spawnLog;
process.env.FAKE_ACP_PROMPT_GATE = promptGate;

const def: ProviderDef = {
  id: "fake-acp-dispose",
  label: "Fake ACP Dispose",
  adapter: "acp",
  cmd: ["bun", `${import.meta.dir}/fake-acp.ts`],
  defaultModel: "fake",
  models: [{ value: "fake", label: "Fake" }],
};
const adapter = makeAcpAdapter(def);
const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "fake-acp-dispose-session",
  provider: def.id,
  cwd: `${import.meta.dir}/../scratch`,
  title: "fake ACP dispose",
  autoApprove: true,
  startOptions: {},
  status: "idle",
  events,
  internal: {},
  emit(evt: AgentEvent) {
    events.push(evt);
  },
  setStatus(status: SessionStatus) {
    this.status = status;
  },
};

async function waitForPrompt(prompt: string) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const delivered = await readFile(promptLog, "utf8");
    if (delivered.split("\n").includes(prompt)) return;
    await Bun.sleep(10);
  }
  throw new Error(`timed out waiting for fake ACP prompt ${JSON.stringify(prompt)}`);
}

try {
  const firstTurn = adapter.send(sess, "first prompt");
  await waitForPrompt("first prompt");
  const secondTurn = adapter.send(sess, "second prompt");

  const eventCountAtDispose = events.length;
  adapter.dispose(sess);
  await writeFile(promptGate, "release\n");
  await Promise.all([firstTurn, secondTurn]);

  const spawned = (await readFile(spawnLog, "utf8")).trim().split(/\n+/).filter(Boolean);
  if (spawned.length !== 1) {
    throw new Error(`disposed ACP session spawned a replacement process: ${JSON.stringify(spawned)}`);
  }
  const delivered = await readFile(promptLog, "utf8");
  if (delivered.split("\n").includes("second prompt")) {
    throw new Error(`disposed ACP session delivered its queued prompt: ${JSON.stringify(delivered)}`);
  }
  if (events.length !== eventCountAtDispose) {
    throw new Error(`disposed ACP session emitted events after disposal: ${JSON.stringify(events.slice(eventCountAtDispose))}`);
  }
  if (events.some((event) => event.kind === "error")) {
    throw new Error(`disposed ACP session emitted an error: ${JSON.stringify(events)}`);
  }
  console.log("acp queued dispose: OK");
} finally {
  adapter.dispose(sess);
  if (previousPromptLog === undefined) delete process.env.FAKE_ACP_PROMPT_LOG;
  else process.env.FAKE_ACP_PROMPT_LOG = previousPromptLog;
  if (previousModelLog === undefined) delete process.env.FAKE_ACP_MODEL_LOG;
  else process.env.FAKE_ACP_MODEL_LOG = previousModelLog;
  if (previousPromptGate === undefined) delete process.env.FAKE_ACP_PROMPT_GATE;
  else process.env.FAKE_ACP_PROMPT_GATE = previousPromptGate;
  await rm(promptGate, { force: true });
}
