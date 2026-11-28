import { readFile, writeFile } from "node:fs/promises";
import { acpPromptFromMail, makeAcpAdapter } from "../adapters/acp";
import type { AgentEvent, ProviderDef, SessionCtx, SessionStatus } from "../types";

const promptLog = `${import.meta.dir}/../scratch/fake-acp-prompts.log`;
await writeFile(promptLog, "");
const previousPromptLog = process.env.FAKE_ACP_PROMPT_LOG;
process.env.FAKE_ACP_PROMPT_LOG = promptLog;

const def: ProviderDef = {
  id: "fake-acp-mail",
  label: "Fake ACP Mail",
  adapter: "acp",
  cmd: ["bun", `${import.meta.dir}/fake-acp.ts`],
};
const adapter = makeAcpAdapter(def);
const events: AgentEvent[] = [];
const sess: SessionCtx = {
  id: "fake-mail-session",
  provider: def.id,
  cwd: `${import.meta.dir}/../scratch`,
  title: "fake mail",
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

const message = {
  id: "msg-42",
  threadId: "thread-7",
  sender: "claude@workspace",
  recipients: ["codex@workspace", "review@workspace"],
  subject: "Review the ACP handoff",
  inReplyTo: "msg-41",
  body: "Please inspect the adapter boundary.\nReply with findings.",
};
const prompt = acpPromptFromMail(message);

try {
  // The adapter still receives an ordinary string prompt. This verifies that
  // a durable message can cross the seam and arrive in ACP unchanged.
  await adapter.send(sess, prompt);
  const delivered = await readFile(promptLog, "utf8");
  if (delivered !== `${prompt}\n`) {
    throw new Error(`ACP prompt did not preserve the mail envelope: ${JSON.stringify(delivered)}`);
  }
  if (events.some((event) => event.kind === "error")) {
    throw new Error(`ACP mail delivery emitted an error: ${JSON.stringify(events)}`);
  }
  console.log("acp durable mail prompt: OK");
} finally {
  adapter.dispose(sess);
  if (previousPromptLog === undefined) delete process.env.FAKE_ACP_PROMPT_LOG;
  else process.env.FAKE_ACP_PROMPT_LOG = previousPromptLog;
}
