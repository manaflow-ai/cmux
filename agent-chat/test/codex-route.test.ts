import { codexSendRouteForTest } from "../adapters/codex";

const completedDuringDeferredDone = codexSendRouteForTest(
  { turnActive: false, currentTurnId: undefined },
  "running",
);
if (completedDuringDeferredDone !== "start") {
  throw new Error(`follow-up after completed turn must start a new turn, got ${completedDuringDeferredDone}`);
}

const activeWithoutStartedNotification = codexSendRouteForTest(
  { turnActive: true, currentTurnId: undefined },
  "running",
);
if (activeWithoutStartedNotification !== "steer") {
  throw new Error(`active starting turn must steer/wait for turn id, got ${activeWithoutStartedNotification}`);
}

const activeWithTurnId = codexSendRouteForTest(
  { turnActive: true, currentTurnId: "turn-1" },
  "idle",
);
if (activeWithTurnId !== "steer") {
  throw new Error(`active turn with id must steer regardless of session status, got ${activeWithTurnId}`);
}

console.log("codex route assertions passed");

export {};
