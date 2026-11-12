import { expect, test } from "bun:test";
import {
  latestRouteStatus,
  normalizeRouteStatus,
  routeHealthForPhase,
} from "../route-status";

test("maps routing lifecycle to provider-neutral health", () => {
  expect(routeHealthForPhase("started")).toBe("unknown");
  expect(routeHealthForPhase("rerouted")).toBe("degraded");
  expect(routeHealthForPhase("handoff")).toBe("degraded");
  expect(routeHealthForPhase("completed")).toBe("healthy");
});

test("normalizes explicit health and preserves route metadata", () => {
  const status = normalizeRouteStatus({
    phase: "rerouted",
    health: "unavailable",
    conversationId: "conversation-1",
    requestId: "request-2",
    attempt: 2,
    provider: "provider-a",
    model: "model-a",
    reason: "capacity",
    retryAfterMs: 5_000,
    at: 1234,
  });
  expect(status).toEqual({
    phase: "rerouted",
    health: "unavailable",
    conversationId: "conversation-1",
    requestId: "request-2",
    attempt: 2,
    provider: "provider-a",
    model: "model-a",
    reason: "capacity",
    retryAfterMs: 5_000,
    updatedAt: 1234,
  });
});

test("falls back safely when a wire event carries an unknown health value", () => {
  const status = normalizeRouteStatus({
    phase: "completed",
    health: "future-health" as never,
    conversationId: "conversation-1",
    requestId: "request-1",
    attempt: 1,
  });
  expect(status.health).toBe("healthy");
});

test("finds the latest valid routing event and ignores malformed history", () => {
  expect(latestRouteStatus([
    { kind: "routing", phase: "started", conversationId: "c", requestId: "r1", attempt: 1 },
    { kind: "status", text: "working" },
    { kind: "routing", phase: "handoff", conversationId: "c2", requestId: "r2", attempt: 1, parentSessionId: "s1" },
  ])).toMatchObject({
    phase: "handoff",
    health: "degraded",
    conversationId: "c2",
    parentSessionId: "s1",
  });
  expect(latestRouteStatus([
    { kind: "routing", phase: "invalid", conversationId: "c", requestId: "r", attempt: 1 },
  ])).toBeNull();
  expect(latestRouteStatus([{ kind: "status", text: "legacy" }])).toBeNull();
});
