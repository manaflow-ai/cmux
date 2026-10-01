// A protocol peer for crash recovery tests; never contacts a provider.
import { appendFileSync, existsSync } from "node:fs";
import { createInterface } from "node:readline";

const root = process.env.CMUX_TEST_CODEX_RECOVERY_DIR!;
appendFileSync(`${root}/pids`, `${process.pid}\n`);
const threads = new Set<string>();
let nextThread = 0;
let nextTurn = 0;
const write = (message: unknown) => process.stdout.write(JSON.stringify(message) + "\n");
for await (const line of createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  const { id, method, params } = message;
  appendFileSync(`${root}/requests`, JSON.stringify({ pid: process.pid, method, params }) + "\n");
  const answer = (result: unknown) => write({ id, result });
  switch (method) {
    case "initialize": answer({}); break;
    case "model/list":
      answer({ data: [{ id: "test-model", model: "test-model", isDefault: true, supportedReasoningEfforts: [] }] });
      break;
    case "collaborationMode/list": answer({ data: [] }); break;
    case "skills/list": answer({ data: [] }); break;
    case "thread/start": {
      const threadId = `thread-${process.pid}-${++nextThread}`;
      threads.add(threadId);
      answer({ thread: { id: threadId } });
      break;
    }
    case "thread/resume":
      if (existsSync(`${root}/refuse-resume`)) {
        write({ id, error: { message: "saved thread is unavailable" } });
      } else {
        threads.add(params.threadId);
        answer({ thread: { id: params.threadId } });
      }
      break;
    case "turn/start": {
      if (!threads.has(params.threadId)) {
        write({ id, error: { message: "thread must be resumed first" } });
        break;
      }
      const turn = { id: `turn-${++nextTurn}` };
      answer({ turn });
      write({ method: "turn/started", params: { threadId: params.threadId, turn } });
      if (params.input[0].text !== "stay active") {
        write({ method: "turn/completed", params: { threadId: params.threadId, turn } });
      }
      break;
    }
    case "turn/steer": answer({}); break;
    default: write({ id, error: { message: `unexpected request ${method}` } });
  }
}
