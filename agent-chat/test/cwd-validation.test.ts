import assert from "node:assert/strict";
import { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { useCwdValidation, useSessionCwdCheck } from "../src/hooks/useCatalogs";
import {
  applyCwdCheckResult,
  type CwdCheck,
  type CwdHarnessRequest,
} from "../src/session";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

interface ProbeProps {
  draft: string;
  committed: string;
  checks: Record<string, CwdCheck>;
  checkCwd: (cwd: string) => CwdHarnessRequest;
  setCwd?: (cwd: string) => void;
  setCommittedCwd?: (cwd: string) => void;
}

function CwdValidationProbe({ draft, committed, checks, checkCwd, setCwd, setCommittedCwd }: ProbeProps) {
  useCwdValidation(
    true,
    1,
    committed,
    draft,
    "/default",
    checks,
    checkCwd,
    setCwd ?? (() => {}),
    setCommittedCwd ?? (() => {}),
  );
  return createElement("input", { value: draft, readOnly: true });
}

function probeElement(props: ProbeProps) {
  return createElement(CwdValidationProbe, props);
}

function SessionProbe({ epoch, checkCwd }: { epoch: number; checkCwd: ProbeProps["checkCwd"] }) {
  // A stream update can replace the action callback while the session's
  // lifecycle inputs remain unchanged. The check must stay once per epoch.
  const streamUpdatedCheck = (cwd: string) => checkCwd(cwd);
  useSessionCwdCheck({
    ready: true,
    connectionEpoch: epoch,
    phase: "chat",
    session: { id: "test", cwd: "/repo", provider: "codex", title: "test", status: "idle" },
    checkCwd: streamUpdatedCheck,
  });
  return null;
}

let renderer: ReactTestRenderer | undefined;
try {
  const requests: string[] = [];
  let requestNumber = 0;
  const checkCwd = (cwd: string): CwdHarnessRequest => {
    requests.push(cwd);
    requestNumber += 1;
    return { requestId: `cwd-${requestNumber}`, cwd, connectionEpoch: 1 };
  };
  const initial = "/default";
  const final = "a".repeat(30);
  const checks: Record<string, CwdCheck> = {};

  act(() => {
    renderer = create(probeElement({ draft: initial, committed: initial, checks, checkCwd }));
  });
  for (let length = 1; length <= final.length; length += 1) {
    act(() => {
      renderer!.update(probeElement({ draft: final.slice(0, length), committed: initial, checks, checkCwd }));
    });
  }
  assert.deepEqual(requests, [initial], "typing a 30-character cwd draft must not validate each prefix");

  act(() => {
    renderer!.update(probeElement({ draft: final, committed: final, checks, checkCwd }));
  });
  assert.deepEqual(requests, [initial, final], "committing the cwd must validate the final value");

  const current: CwdHarnessRequest = { requestId: "current", cwd: final, connectionEpoch: 2 };
  const accepted = applyCwdCheckResult(checks, current, {
    requestId: current.requestId,
    cwd: current.cwd,
    connectionEpoch: current.connectionEpoch,
    ok: true,
  });
  const stale = applyCwdCheckResult(accepted, current, {
    requestId: "previous-request",
    cwd: current.cwd,
    connectionEpoch: current.connectionEpoch,
    ok: false,
    message: "stale failure",
  });
  assert.strictEqual(stale, accepted, "a stale cwd failure must not update visible validation state");
  assert.equal(stale[final]?.ok, true, "the final success must remain selected after a stale failure");

  const failedCommitted = "/missing";
  const draftAfterCommit = "/new-draft";
  const fallbackCalls: string[] = [];
  let failedChecks: Record<string, CwdCheck> = {};
  const recordFallback = (cwd: string) => fallbackCalls.push(cwd);
  let failedRequest: CwdHarnessRequest | undefined;
  const failedCheckCwd = (cwd: string): CwdHarnessRequest => {
    failedRequest = { requestId: "failed-commit", cwd, connectionEpoch: 1 };
    return failedRequest;
  };
  act(() => {
    renderer!.update(probeElement({
      draft: failedCommitted,
      committed: failedCommitted,
      checks: failedChecks,
      checkCwd: failedCheckCwd,
    }));
  });
  act(() => {
    renderer!.update(probeElement({
      draft: draftAfterCommit,
      committed: failedCommitted,
      checks: failedChecks,
      checkCwd: failedCheckCwd,
      setCwd: recordFallback,
      setCommittedCwd: recordFallback,
    }));
  });
  failedChecks = { [failedCommitted]: {
    ok: false,
    requestId: failedRequest!.requestId,
    connectionEpoch: failedRequest!.connectionEpoch,
  } };
  act(() => {
    renderer!.update(probeElement({
      draft: draftAfterCommit,
      committed: failedCommitted,
      checks: failedChecks,
      checkCwd: failedCheckCwd,
      setCwd: recordFallback,
      setCommittedCwd: recordFallback,
    }));
  });
  assert.deepEqual(fallbackCalls, [], "a committed cwd failure must not reset a newer draft");
  requests.length = 0;
  act(() => { renderer!.update(createElement(SessionProbe, { epoch: 1, checkCwd })); });
  for (let event = 0; event < 8; event += 1) {
    act(() => { renderer!.update(createElement(SessionProbe, { epoch: 1, checkCwd })); });
  }
  assert.deepEqual(requests, ["/repo"], "stream renders must not repeat the session check");
  act(() => { renderer!.update(createElement(SessionProbe, { epoch: 2, checkCwd })); });
  assert.deepEqual(requests, ["/repo", "/repo"], "reconnect revalidates the same session directory");
  let unavailableCalls = 0;
  const unavailableCheck = (): CwdHarnessRequest | null => {
    unavailableCalls += 1;
    return null;
  };
  act(() => { renderer!.update(createElement(SessionProbe, { epoch: 3, checkCwd: unavailableCheck })); });
  for (let event = 0; event < 8; event += 1) {
    act(() => { renderer!.update(createElement(SessionProbe, { epoch: 3, checkCwd: unavailableCheck })); });
  }
  assert.equal(unavailableCalls, 1, "a stream render must not retry an unavailable lifecycle check");
  console.log("cwd validation: 30-character burst, commit, stale failure, newer draft and reconnect: OK");
} finally {
  if (renderer) act(() => renderer!.unmount());
}
