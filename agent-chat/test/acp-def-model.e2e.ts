import { readFile, writeFile } from "node:fs/promises";
import { makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionOption, SessionStatus } from "../types";

const log = `${import.meta.dir}/../scratch/fake-acp-models.log`;
await writeFile(log, "");
const previousLog = process.env.FAKE_ACP_MODEL_LOG;
process.env.FAKE_ACP_MODEL_LOG = log;

const def: ProviderDef = {
  id: "fake-acp",
  label: "Fake ACP",
  adapter: "acp",
  cmd: ["bun", `${import.meta.dir}/fake-acp.ts`],
  defaultModel: "fake-a",
  models: [
    { value: "fake-a", label: "Fake A" },
    { value: "fake-b", label: "Fake B" },
  ],
};

const adapter = makeAcpAdapter(def);
const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "fake-session",
  provider: def.id,
  cwd: `${import.meta.dir}/../scratch`,
  title: "fake",
  autoApprove: true,
  startOptions: { model: "fake-b" },
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

function latestOptions(): SessionOption[] {
  const evt = [...events].reverse().find((e) => e.kind === "options");
  return evt?.kind === "options" ? evt.options : [];
}

function modelValue(): string {
  const model = latestOptions().find((o) => o.id === "model");
  return String(model?.value ?? "");
}

async function spawnedModels(): Promise<string[]> {
  return (await readFile(log, "utf8")).trim().split(/\n+/).filter(Boolean);
}

try {
  await adapter.refreshOptions?.(sess);
  if (modelValue() !== "fake-b") {
    throw new Error(`preseed model mismatch: expected fake-b, got ${JSON.stringify(modelValue())}`);
  }
  let models = await spawnedModels();
  if (models.length !== 1 || models[0] !== "fake-b") {
    throw new Error(`preseed spawn mismatch: ${JSON.stringify(models)}`);
  }

  await adapter.setOption(sess, "model", "fake-a");
  if (modelValue() !== "fake-a") {
    throw new Error(`mid-session model mismatch: expected fake-a, got ${JSON.stringify(modelValue())}`);
  }
  models = await spawnedModels();
  if (models.length !== 2 || models[1] !== "fake-a") {
    throw new Error(`restart spawn mismatch: ${JSON.stringify(models)}`);
  }
  if (events.some((e) => e.kind === "error" && /ReferenceError|def is not defined/.test(e.message))) {
    throw new Error("ReferenceError surfaced during def-backed model change");
  }

  console.log("acp def-backed model: OK");
} finally {
  adapter.dispose(sess);
  if (previousLog === undefined) delete process.env.FAKE_ACP_MODEL_LOG;
  else process.env.FAKE_ACP_MODEL_LOG = previousLog;
}
