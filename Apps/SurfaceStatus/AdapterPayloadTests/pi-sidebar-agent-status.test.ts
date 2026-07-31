import assert from "node:assert/strict";
import test from "node:test";

import { classifyRetryableError, PiSidebarLifecycle } from "./pi-sidebar-agent-status.ts";

const assistantError = (errorMessage: string) => [{ role: "assistant", stopReason: "error", errorMessage }];

function harness(debounce = 5) {
  const reports: Array<{ state: string; reason?: string }> = [];
  const lifecycle = new PiSidebarLifecycle((report) => reports.push(report), debounce);
  return { lifecycle, reports };
}

const delay = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));

test("normal completion is published only after agent_settled", async () => {
  const { lifecycle, reports } = harness();
  lifecycle.sessionStart(true);
  lifecycle.agentStart();
  lifecycle.agentEnd([{ role: "assistant", stopReason: "stop" }]);
  assert.deepEqual(reports.map((report) => report.state), ["idle", "running"]);

  lifecycle.agentSettled();
  assert.equal(reports.at(-1)?.state, "running");
  await delay(10);
  assert.equal(reports.at(-1)?.state, "done");
});

test("a retry between agent_end and agent_settled never flashes done or rate limited", async () => {
  const { lifecycle, reports } = harness();
  lifecycle.sessionStart(true);
  lifecycle.agentStart();
  lifecycle.agentEnd(assistantError('Error: 429: {"message":"Quota exceeded: Every 5 hours"}'));
  lifecycle.agentStart();
  lifecycle.agentEnd([{ role: "assistant", stopReason: "stop" }]);
  lifecycle.agentSettled();
  await delay(10);

  assert.deepEqual(reports.map((report) => report.state), ["idle", "running", "done"]);
});

test("exhausted rate limit is retained at the settled boundary", async () => {
  const { lifecycle, reports } = harness();
  lifecycle.sessionStart(true);
  lifecycle.agentStart();
  lifecycle.agentEnd(assistantError('Error: 429: {"type":"rate_limit_error","message":"Quota exceeded: Every 5 hours"}'));
  lifecycle.agentSettled();
  await delay(10);

  assert.deepEqual(reports.at(-1), {
    state: "rateLimited",
    reason: "rateLimit",
  });
});

test("exhausted transient provider failure becomes needs input with an error reason", async () => {
  const { lifecycle, reports } = harness();
  lifecycle.sessionStart(true);
  lifecycle.agentStart();
  lifecycle.agentEnd(assistantError("503 service unavailable"));
  lifecycle.agentSettled();
  await delay(10);

  assert.equal(reports.at(-1)?.state, "needsInput");
  assert.equal(reports.at(-1)?.reason, "error");
});

test("nested blockers outrank running and restore the underlying state", async () => {
  const { lifecycle, reports } = harness();
  lifecycle.sessionStart(true);
  lifecycle.agentStart();
  lifecycle.blocker(true, "Permission");
  lifecycle.blocker(true, "Question");
  lifecycle.blocker(false);
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker(false);
  assert.equal(reports.at(-1)?.state, "running");

  lifecycle.agentEnd([{ role: "assistant", stopReason: "stop" }]);
  lifecycle.agentSettled();
  lifecycle.blocker(true, "Review response");
  await delay(10);
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker(false);
  assert.equal(reports.at(-1)?.state, "done");
});

test("duplicate agent_end cannot overwrite the completed attempt result", async () => {
  const { lifecycle, reports } = harness();
  lifecycle.sessionStart(true);
  lifecycle.agentStart();
  lifecycle.agentEnd([{ role: "assistant", stopReason: "stop" }]);
  lifecycle.agentEnd(assistantError("429 quota exceeded"));
  lifecycle.agentSettled();
  await delay(10);
  assert.equal(reports.at(-1)?.state, "done");
});

test("classifier requires a retryable assistant error", () => {
  assert.equal(classifyRetryableError([{ role: "assistant", stopReason: "stop" }]), undefined);
  assert.equal(classifyRetryableError(assistantError("invalid request")), undefined);
  assert.equal(classifyRetryableError(assistantError("Quota exceeded: Every 5 hours"))?.reason, "rateLimit");
});
