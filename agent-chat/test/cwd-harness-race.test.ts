import { expect, test } from "bun:test";
import { acceptsCwdHarnessResponse, type CwdHarnessRequest } from "../src/session";

const request = (requestId: string, cwd: string, connectionEpoch = 1): CwdHarnessRequest => ({
  requestId,
  cwd,
  connectionEpoch,
});

test("ignores an older cwd response after the cwd changes", () => {
  const active = request("b", "/repo/b");

  expect(acceptsCwdHarnessResponse(active, { requestId: "a", cwd: "/repo/a", connectionEpoch: 1 })).toBe(false);
  expect(acceptsCwdHarnessResponse(active, { requestId: "b", cwd: "/repo/b", connectionEpoch: 1 })).toBe(true);
});

test("does not accept an old response when the cwd returns to the same path", () => {
  const active = request("a-2", "/repo/a");

  expect(acceptsCwdHarnessResponse(active, { requestId: "a-1", cwd: "/repo/a", connectionEpoch: 1 })).toBe(false);
  expect(acceptsCwdHarnessResponse(active, { requestId: "a-2", cwd: "/repo/a", connectionEpoch: 1 })).toBe(true);
});

test("does not accept a response from a previous websocket connection", () => {
  const active = request("a-1", "/repo/a", 2);

  expect(acceptsCwdHarnessResponse(active, { requestId: "a-1", cwd: "/repo/a", connectionEpoch: 1 })).toBe(false);
  expect(acceptsCwdHarnessResponse(active, { requestId: "a-1", cwd: "/repo/a", connectionEpoch: 2 })).toBe(true);
});
