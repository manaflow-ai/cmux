import type { Id } from "@cmux/convex/dataModel";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  resumeDockerRun,
  terminateDockerRun,
} from "./agentSpawner.js";
import { ensureRunWorktreeAndBranch } from "./utils/ensureRunWorktree.js";
import { getConvex } from "./utils/convexClient.js";
import { runWithAuth } from "./utils/requestContext.js";
import {
  DockerVSCodeInstance,
  containerMappings,
} from "./vscode/DockerVSCodeInstance.js";

vi.mock("./utils/ensureRunWorktree.js", () => ({
  ensureRunWorktreeAndBranch: vi.fn(),
}));

const queryMock = vi.fn();
const mutationMock = vi.fn();

vi.mock("./utils/convexClient.js", () => ({
  getConvex: vi.fn(() => ({
    query: queryMock,
    mutation: mutationMock,
  })),
}));

describe("run lifecycle helpers", () => {
  const taskRunId = "test-run" as Id<"taskRuns">;
  const taskId = "test-task" as Id<"tasks">;
  const teamSlugOrId = "default";

  beforeEach(() => {
    vi.clearAllMocks();
    queryMock.mockReset();
    mutationMock.mockReset();
    containerMappings.clear();
  });

  it("resumes a warm session with existing volumes", async () => {
    const volumes = {
      workspace: "cmux_session_test-run_workspace",
      vscode: "cmux_session_test-run_vscode",
    };

    const ensureMock = vi.mocked(ensureRunWorktreeAndBranch);
    ensureMock.mockResolvedValue({
      run: {
        _id: taskRunId,
        taskId,
        agentName: "cmux/mock",
        worktreePath: "/tmp/mock-workspace",
        vscode: {
          provider: "docker",
          status: "stopped",
          volumes,
          lastActivityAt: Date.now() - 60_000,
          containerName: `cmux-${taskRunId}`,
        },
      } as any,
      task: {} as any,
      worktreePath: "/tmp/mock-workspace",
      branchName: "cmux-branch",
      baseBranch: "main",
    });

    const startSpy = vi
      .spyOn(DockerVSCodeInstance.prototype, "start")
      .mockResolvedValue({
        url: "http://localhost:48000",
        workspaceUrl: "http://localhost:48000/?folder=/root/workspace",
        instanceId: taskRunId,
        taskRunId,
        provider: "docker",
      });

    const fileWatchSpy = vi
      .spyOn(DockerVSCodeInstance.prototype, "startFileWatch")
      .mockImplementation(() => {});
    const recordSpy = vi
      .spyOn(DockerVSCodeInstance.prototype, "recordActivity")
      .mockImplementation(() => {});
    const volumeSpy = vi
      .spyOn(DockerVSCodeInstance.prototype, "getSessionVolumes")
      .mockReturnValue(volumes);
    const retentionSpy = vi
      .spyOn(DockerVSCodeInstance.prototype, "getWarmRetentionMs")
      .mockReturnValue(3_600_000);
    const containerIdSpy = vi
      .spyOn(DockerVSCodeInstance.prototype, "getContainerId")
      .mockReturnValue("container-123");

    await runWithAuth("token", undefined, async () => {
      const result = await resumeDockerRun(taskRunId, teamSlugOrId);
      expect(result.info.workspaceUrl).toContain("/root/workspace");
    });

    expect(startSpy).toHaveBeenCalledTimes(1);
    const updateCall = mutationMock.mock.calls.find(([, payload]) =>
      Boolean((payload as Record<string, unknown>).vscode)
    );
    expect(updateCall).toBeTruthy();
    expect(updateCall?.[1]).toMatchObject({
      teamSlugOrId,
      id: taskRunId,
      vscode: expect.objectContaining({
        volumes,
        sessionStatus: "active",
        containerId: "container-123",
      }),
    });

    startSpy.mockRestore();
    fileWatchSpy.mockRestore();
    recordSpy.mockRestore();
    volumeSpy.mockRestore();
    retentionSpy.mockRestore();
    containerIdSpy.mockRestore();
  });

  it("terminates a session and removes mapping", async () => {
    const dockerStop = vi.fn().mockResolvedValue(undefined);
    const dockerSpy = vi
      .spyOn(DockerVSCodeInstance, "getDocker")
      .mockReturnValue({
        getContainer: () => ({
          stop: dockerStop,
        }),
      } as unknown as ReturnType<typeof DockerVSCodeInstance.getDocker>);

    const terminateSpy = vi
      .spyOn(DockerVSCodeInstance, "terminateSessionFromMapping")
      .mockResolvedValue(undefined);

    queryMock.mockResolvedValue({
      _id: taskRunId,
      taskId,
      worktreePath: "/tmp/mock-workspace",
      vscode: {
        provider: "docker",
        status: "stopped",
        volumes: {
          workspace: "cmux_session_test-run_workspace",
          vscode: "cmux_session_test-run_vscode",
        },
        containerName: `cmux-${taskRunId}`,
      },
    });

    await runWithAuth("token", undefined, async () => {
      await terminateDockerRun(taskRunId, teamSlugOrId);
    });

    dockerSpy.mockRestore();

    expect(dockerStop).toHaveBeenCalled();
    expect(
      (DockerVSCodeInstance.terminateSessionFromMapping as vi.Mock).mock.calls[0][0]
        .sessionStatus
    ).toBe("terminated");
    const statusCall = mutationMock.mock.calls.find(([, payload]) =>
      (payload as Record<string, unknown>).status === "stopped"
    );
    expect(statusCall).toBeTruthy();
    expect(statusCall?.[1]).toMatchObject({
      teamSlugOrId,
      id: taskRunId,
      status: "stopped",
      sessionStatus: "terminated",
    });

    terminateSpy.mockRestore();
  });

  it("removes warm sessions that exceed retention window", async () => {
    const removeVolume = vi.fn().mockResolvedValue(undefined);
    const dockerStub = {
      getContainer: () => ({
        stop: vi.fn().mockResolvedValue(undefined),
        remove: vi.fn().mockResolvedValue(undefined),
      }),
      getVolume: vi.fn(() => ({ remove: removeVolume })),
    };

    const dockerLifeSpy = vi
      .spyOn(DockerVSCodeInstance, "getDocker")
      .mockReturnValue(
        dockerStub as unknown as ReturnType<typeof DockerVSCodeInstance.getDocker>
      );

    const now = Date.now();
    containerMappings.set(`cmux-${taskRunId}`, {
      containerName: `cmux-${taskRunId}`,
      instanceId: taskRunId,
      teamSlugOrId,
      authToken: "token",
      ports: { vscode: "", worker: "" },
      status: "warm",
      volumes: {
        workspace: "cmux_session_test-run_workspace",
        vscode: "cmux_session_test-run_vscode",
      },
      lastActivityAt: now - 120_000,
      idleTimeoutMs: 60_000,
      warmExpiresAt: now - 1,
      sessionStatus: "warm",
      warmRetentionMs: 60_000,
    });

    queryMock.mockResolvedValue({
      _id: taskRunId,
      taskId,
      worktreePath: "/tmp/mock-workspace",
      vscode: {
        provider: "docker",
        status: "stopped",
        volumes: {
          workspace: "cmux_session_test-run_workspace",
          vscode: "cmux_session_test-run_vscode",
        },
        containerName: `cmux-${taskRunId}`,
      },
    });

    await runWithAuth("token", undefined, async () => {
      await (DockerVSCodeInstance as any).runLifecycleSweep();
    });

    expect(removeVolume).toHaveBeenCalledTimes(2);
    expect(containerMappings.has(`cmux-${taskRunId}`)).toBe(false);

    dockerLifeSpy.mockRestore();
  });
});
