import { serverLogger } from "./utils/fileLogger";
import { resolveWorkerRepoPath } from "./utils/resolveWorkerRepoPath";
import { workerExec } from "./utils/workerExec";
import type { VSCodeInstance } from "./vscode/VSCodeInstance";

export async function captureGitDiff(
  vscodeInstance: VSCodeInstance,
  worktreePath: string
): Promise<string> {
  if (!vscodeInstance.isWorkerConnected()) {
    serverLogger.warn(
      `[AgentSpawner] Cannot capture git diff — worker not connected for ${worktreePath}`
    );
    throw new Error(
      `[AgentSpawner] Cannot capture git diff — worker not connected for ${worktreePath}`
    );
  }

  try {
    const workerSocket = vscodeInstance.getWorkerSocket();
    serverLogger.info(
      `[AgentSpawner] Collecting relevant git diff for ${worktreePath}`
    );
    const containerWorkspacePath = vscodeInstance.getContainerWorkspacePath();

    const repoCwd = await resolveWorkerRepoPath({
      workerSocket,
      initialCwd: containerWorkspacePath,
      fallbackCwd: containerWorkspacePath,
    });
    serverLogger.info(`[AgentSpawner] Running diff script from ${repoCwd}`);

    const { stdout, stderr, exitCode } = await workerExec({
      workerSocket,
      command: "/bin/bash",
      args: ["-c", "/usr/local/bin/cmux-collect-relevant-diff.sh"],
      cwd: repoCwd,
      env: {},
      timeout: 30000,
    });

    if (exitCode !== 0) {
      serverLogger.warn(
        `[AgentSpawner] Diff script exited with ${exitCode}. stderr: ${stderr.slice(0, 500)}`
      );
    }

    const diff = stdout?.trim() ?? "";
    serverLogger.info(
      `[AgentSpawner] Captured ${diff.length} chars of relevant diff for ${worktreePath}`
    );

    return diff || "No changes detected";
  } catch (error) {
    serverLogger.error(`[AgentSpawner] Error capturing git diff:`, error);
    throw new Error(`[AgentSpawner] Error capturing git diff`, {
      cause: error,
    });
  }
}
