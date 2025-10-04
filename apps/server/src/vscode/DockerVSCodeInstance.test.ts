import type { Id } from "@cmux/convex/dataModel";
import { spawn } from "node:child_process";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  DockerVSCodeInstance,
  containerMappings,
} from "./DockerVSCodeInstance";

vi.mock("../utils/convexClient.js", () => ({
  convex: {
    mutation: vi.fn().mockResolvedValue(undefined),
    query: vi.fn().mockResolvedValue({
      autoCleanupEnabled: false,
      maxRunningContainers: 0,
      reviewPeriodMinutes: 0,
    }),
  },
}));

vi.mock("../utils/fileLogger.js", () => ({
  dockerLogger: {
    info: vi.fn(),
    error: vi.fn(),
    warn: vi.fn(),
  },
}));

describe("DockerVSCodeInstance", () => {
  it("should prefix container names with 'docker-'", () => {
    // Create instance with a test taskRunId
    const taskRunId = "test123456789012345678901234" as Id<"taskRuns">;
    const taskId = "task123456789012345678901234" as Id<"tasks">;

    const instance = new DockerVSCodeInstance({
      taskRunId,
      taskId,
      teamSlugOrId: "default",
    });

    // Verify getName() returns the prefixed name
    const name = instance.getName();
    expect(name).toMatch(/^docker-cmux-/);
    expect(name).toBe(`docker-cmux-${taskRunId}`);
  });

  it("should always return docker- prefixed names for different taskRunIds", () => {
    const testCases = [
      "abcd1234567890abcdef12345678" as Id<"taskRuns">,
      "xyz9876543210xyzabc123456789" as Id<"taskRuns">,
      "000000000000111122223333444" as Id<"taskRuns">,
    ];

    const taskId = "task123456789012345678901234" as Id<"tasks">;

    for (const taskRunId of testCases) {
      const instance = new DockerVSCodeInstance({
        taskRunId,
        taskId,
        teamSlugOrId: "default",
      });
      expect(instance.getName()).toBe(`docker-cmux-${taskRunId}`);
    }
  });

  it("ensures docker- prefix distinguishes from other providers", () => {
    // This test verifies the docker- prefix is used as a failsafe to identify Docker instances
    const taskRunId = "jn75ppcyksmh1234567890123456" as Id<"taskRuns">;
    const taskId = "task123456789012345678901234" as Id<"tasks">;

    const instance = new DockerVSCodeInstance({
      taskRunId,
      taskId,
      teamSlugOrId: "default",
    });

    const name = instance.getName();

    // Should have docker- prefix
    expect(name.startsWith("docker-")).toBe(true);
    // Should contain the cmux- prefix after docker-
    expect(name).toBe(`docker-cmux-${taskRunId}`);

    // The actual container name (without docker- prefix) should be cmux-jn75ppcyksmh
    // This is what Docker sees as the container name
    const actualDockerContainerName = name.replace("docker-", "");
    expect(actualDockerContainerName).toBe(`cmux-${taskRunId}`);
  });

  describe("docker event syncing", () => {
    let dockerAvailable = false;

    beforeAll(async () => {
      dockerAvailable = await new Promise<boolean>((resolve) => {
        const proc = spawn("docker", ["--version"]);
        proc.on("exit", (code) => resolve(code === 0));
        proc.on("error", () => resolve(false));
      });
      if (dockerAvailable) {
        DockerVSCodeInstance.startContainerStateSync();
      }
    });

    afterAll(() => {
      if (dockerAvailable) {
        DockerVSCodeInstance.stopContainerStateSync();
      }
      containerMappings.clear();
    });

    it(
      "updates mapping status on container start and stop",
      {
        skip: true, // TODO: re-enable after docker outage is fixed
        timeout: 15000,
      },
      async () => {
        if (!dockerAvailable) {
          console.warn("Docker not available, skipping test");
          return;
        }

        // Pre-clean any existing container with the same name to avoid name conflicts
        await new Promise<void>((resolve) => {
          const cleanup = spawn("docker", ["rm", "-f", "cmux-test"]);
          // ignore errors; container may not exist
          cleanup.on("exit", () => resolve());
          cleanup.on("error", () => resolve());
        });

        containerMappings.set("cmux-test", {
          containerName: "cmux-test",
          instanceId: "test-instance" as Id<"taskRuns">,
          teamSlugOrId: "default",
        ports: { vscode: "", worker: "", proxy: "" },
          status: "starting",
        });

        // ensure listener is ready
        await new Promise((r) => setTimeout(r, 200));

        await new Promise<void>((resolve, reject) => {
          const proc = spawn("docker", [
            "run",
            "-d",
            "--rm",
            "--name",
            "cmux-test",
            "busybox",
            "sleep",
            "2",
          ]);
          let stderr = "";
          proc.stderr?.on("data", (d) => {
            stderr += d.toString();
          });
          proc.on("exit", (code) => {
            if (code === 0) {
              resolve();
            } else {
              const msg = stderr.trim();
              console.error("docker run failed", msg);
              reject(new Error(`docker run failed${msg ? `: ${msg}` : ""}`));
            }
          });
          proc.on("error", (err) => {
            const msg = stderr.trim();
            reject(
              new Error(
                `docker run error${msg ? `: ${msg}` : ""}: ${String(err)}`
              )
            );
          });
        });

        await new Promise((r) => setTimeout(r, 500));
        expect(containerMappings.get("cmux-test")?.status).toBe("running");

        await new Promise((r) => setTimeout(r, 2500));
        expect(containerMappings.get("cmux-test")?.status).toBe("stopped");
      }
    );
  });
});
