import assert from "node:assert/strict";
import test from "node:test";

import {
  classifyOpenCodeError,
  directStatusRecord,
  OpenCodeSidebarLifecycle,
} from "../SurfaceStatusApp/AdapterPayloads/opencode-sidebar-agent-status.mjs";

function harness() {
  const reports = [];
  const lifecycle = new OpenCodeSidebarLifecycle((report) => reports.push(report));
  lifecycle.publishInitial();
  return { lifecycle, reports };
}

test("initial idle stays idle and post-work idle becomes done", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "root" }, "root");
  lifecycle.idle("root");
  lifecycle.working("root");
  lifecycle.idle("root");
  assert.deepEqual(reports.map((report) => report.state), ["idle", "running", "done"]);
});

test("child work cannot clobber root state", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "root" }, "root");
  lifecycle.working("root");
  lifecycle.observeSession({ id: "child", parentID: "root" }, "child");
  lifecycle.idle("child");
  assert.equal(reports.at(-1)?.state, "running");
});

test("child blockers surface and restore the root state", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "root" }, "root");
  lifecycle.working("root");
  lifecycle.observeSession({ id: "child", parentID: "root" }, "child");
  lifecycle.blocker("child", "question", true);
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker("child", "question", false);
  assert.equal(reports.at(-1)?.state, "running");
});

test("nested blockers remain blocked until all are answered", () => {
  const { lifecycle, reports } = harness();
  lifecycle.working("root");
  lifecycle.blocker("root", "permission", true);
  lifecycle.blocker("root", "question", true);
  lifecycle.blocker("root", "permission", false);
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker("root", "question", false);
  assert.equal(reports.at(-1)?.state, "running");
});

test("rate limit and provider errors are classified without chat content", () => {
  assert.deepEqual(classifyOpenCodeError({ error: { message: "429 quota exceeded" } }), {
    state: "rateLimited",
    reason: "rateLimit",
  });
  assert.deepEqual(classifyOpenCodeError({ error: { message: "503 service unavailable" } }), {
    state: "needsInput",
    reason: "error",
  });
  assert.deepEqual(classifyOpenCodeError({ error: { message: "invalid request" } }), {
    state: "needsInput",
    reason: "error",
  });
});

test("unrelated roots cannot steal ownership or raise blockers", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "root-a" }, "root-a");
  lifecycle.working("root-a");
  lifecycle.observeSession({ id: "root-b" }, "root-b");
  lifecycle.idle("root-b");
  lifecycle.blocker("root-b", "question", true);
  assert.equal(lifecycle.rootSessionID, "root-a");
  assert.equal(reports.at(-1)?.state, "running");
});

test("children of unrelated roots cannot raise blockers", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "root-a" }, "root-a");
  lifecycle.working("root-a");
  lifecycle.observeSession({ id: "child-b", parentID: "root-b" }, "child-b");
  lifecycle.blocker("child-b", "permission", true);
  assert.equal(reports.at(-1)?.state, "running");
});

test("terminal errors remain latched across idle and clear on new work", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "root" }, "root");
  lifecycle.working("root");
  lifecycle.error("root", { error: { message: "429 quota exceeded" } });
  lifecycle.idle("root");
  assert.equal(reports.at(-1)?.state, "rateLimited");
  lifecycle.working("root");
  lifecycle.idle("root");
  assert.equal(reports.at(-1)?.state, "done");
});

test("owned root release permits a clean new root", () => {
  const { lifecycle, reports } = harness();
  lifecycle.working("root-a");
  lifecycle.error("root-a", { error: { message: "provider failed" } });
  assert.equal(lifecycle.release("root-b"), false);
  assert.equal(lifecycle.rootSessionID, "root-a");
  assert.equal(lifecycle.release("root-a"), true);
  lifecycle.idle("root-b");
  assert.equal(lifecycle.rootSessionID, "root-b");
  assert.equal(reports.at(-1)?.state, "idle");
});

test("metadata-only root observation does not claim surface ownership", () => {
  const { lifecycle } = harness();
  lifecycle.observeSession({ id: "restored-background-root" }, "restored-background-root");
  assert.equal(lifecycle.rootSessionID, undefined);
  lifecycle.working("visible-root");
  assert.equal(lifecycle.rootSessionID, "visible-root");
});

test("simultaneous same-kind blockers require distinct replies", () => {
  const { lifecycle, reports } = harness();
  lifecycle.working("root");
  lifecycle.blocker("root", "permission", true, "request-a");
  lifecycle.blocker("root", "permission", true, "request-b");
  lifecycle.blocker("root", "permission", false, "request-a");
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker("root", "permission", false, "request-b");
  assert.equal(reports.at(-1)?.state, "running");
});

test("same-kind blockers without request ids use safe counters", () => {
  const { lifecycle, reports } = harness();
  lifecycle.working("root");
  lifecycle.blocker("root", "question", true);
  lifecycle.blocker("root", "question", true);
  lifecycle.blocker("root", "question", false);
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker("root", "question", false);
  assert.equal(reports.at(-1)?.state, "running");
});

test("blocker replies degrade safely when request ids are omitted", () => {
  const { lifecycle, reports } = harness();
  lifecycle.working("root");
  lifecycle.blocker("root", "permission", true, "request-a");
  lifecycle.blocker("root", "permission", true, "request-b");
  lifecycle.blocker("root", "permission", false);
  assert.equal(reports.at(-1)?.state, "needsInput");
  lifecycle.blocker("root", "permission", false);
  assert.equal(reports.at(-1)?.state, "running");
});

test("a child blocker claims its observed root, not the child", () => {
  const { lifecycle, reports } = harness();
  lifecycle.observeSession({ id: "child", parentID: "root" }, "child");
  lifecycle.blocker("child", "question", true, "request");
  assert.equal(lifecycle.rootSessionID, "root");
  assert.equal(reports.at(-1)?.state, "needsInput");
});

test("direct status record carries process birth identity schema", () => {
  assert.deepEqual(directStatusRecord(
    { state: "needsInput", reason: "interaction" },
    {
      surfaceID: "11111111-2222-3333-4444-555555555555",
      workspaceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      pid: 42,
      processStartedAt: 1_000.25,
      updatedAt: 1_001,
    },
  ), {
    version: 3,
    agentID: "opencode",
    surfaceID: "11111111-2222-3333-4444-555555555555",
    workspaceID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    state: "needsInput",
    reason: "interaction",
    pid: 42,
    processStartedAt: 1_000.25,
    updatedAt: 1_001,
  });
});
