import assert from "node:assert/strict";
import React, { createElement } from "react";
import { act, create, type ReactTestRenderer } from "react-test-renderer";
import { useCwdValidation } from "../src/hooks/useCatalogs";
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
}

function CwdValidationProbe({ draft, committed, checks, checkCwd }: ProbeProps) {
  useCwdValidation(
    true,
    1,
    committed,
    "/default",
    checks,
    checkCwd,
    () => {},
    () => {},
  );
  return createElement("input", { value: draft, readOnly: true });
}

function probeElement(props: ProbeProps) {
  return createElement(CwdValidationProbe, props);
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
  let accepted = applyCwdCheckResult(checks, current, {
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
  console.log("cwd draft validation stays local during typing, validates on commit, and rejects stale failures: OK");
} finally {
  if (renderer) act(() => renderer!.unmount());
}
