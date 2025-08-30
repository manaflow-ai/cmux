import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import type { FunctionReturnType } from "convex/server";
import { describe, expect, it, vi } from "vitest";

// Mock morphcloud before importing the module under test
vi.mock("morphcloud", () => {
  const pauseMock = vi.fn(async () => {});
  const getMock = vi.fn(async (_args: { instanceId: string }) => ({
    pause: pauseMock,
  }));
  class MorphCloudClient {
    instances = { get: getMock };
  }
  return { MorphCloudClient, testing: { pauseMock, getMock } };
});

// Silence file logging
vi.mock("./utils/fileLogger.js", () => ({
  serverLogger: {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    close: vi.fn(),
  },
  dockerLogger: {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    close: vi.fn(),
  },
}));

import * as morphMod from "morphcloud";
import { stopContainersForRunsFromTree } from "./archiveTask.js";

describe("stopContainersForRunsFromTree - morph path", () => {
  it("pauses morph instance for morph provider runs", async () => {
    const zidRun = typedZid("taskRuns");
    const zidTask = typedZid("tasks");
    const now = Date.now();
    const instanceId = "morphvm_test_instance";

    const tree = [
      {
        _id: zidRun.parse("rm1"),
        _creationTime: now,
        taskId: zidTask.parse("tm1"),
        prompt: "p",
        status: "running",
        log: "",
        createdAt: now,
        updatedAt: now,
        userId: "test-user",
        teamId: "default",
        vscode: {
          provider: "morph",
          status: "running",
          containerName: instanceId,
        },
        children: [],
      },
    ] satisfies FunctionReturnType<typeof api.taskRuns.getByTask>;

    const results = await stopContainersForRunsFromTree(tree, "tm1");
    expect(results).toHaveLength(1);
    expect(results[0]?.success).toBe(true);

    const testing = Reflect.get(morphMod as object, "testing");
    if (
      typeof testing === "object" &&
      testing !== null &&
      typeof Reflect.get(testing as object, "pauseMock") === "function" &&
      typeof Reflect.get(testing as object, "getMock") === "function"
    ) {
      const pauseMock = Reflect.get(testing as object, "pauseMock");
      const getMock = Reflect.get(testing as object, "getMock");
      expect(getMock as (...args: unknown[]) => unknown).toHaveBeenCalledTimes(
        1
      );
      const firstCallArgs = (getMock as { mock: { calls: unknown[][] } }).mock
        .calls[0] as [{ instanceId: string }];
      expect(firstCallArgs[0]?.instanceId).toBe(instanceId);
      expect(
        pauseMock as (...args: unknown[]) => unknown
      ).toHaveBeenCalledTimes(1);
    } else {
      throw new Error("Morph mock not found");
    }
  });
});
