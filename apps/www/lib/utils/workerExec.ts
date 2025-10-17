import type { ServerToWorkerEvents, WorkerToServerEvents } from "@cmux/shared";
import type { Socket } from "@cmux/shared/socket";

export async function workerExec({
  workerSocket,
  command,
  args,
  cwd,
  env,
  timeout = 60_000,
}: {
  workerSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents>;
  command: string;
  args: string[];
  cwd: string;
  env: Record<string, string>;
  timeout?: number;
}): Promise<{
  stdout: string;
  stderr: string;
  exitCode: number;
  error?: string;
}> {
  return new Promise((resolve, reject) => {
    try {
      workerSocket
        .timeout(timeout)
        .emit("worker:exec", { command, args, cwd, env }, (error, payload) => {
          if (error) {
            if (
              error instanceof Error &&
              error.message === "operation has timed out"
            ) {
              console.error(
                `[workerExec] Socket timeout for command: ${command}`,
                error,
              );
              reject(
                new Error(`Command timed out after ${timeout}ms: ${command}`),
              );
            } else {
              reject(error);
            }
            return;
          }
          if (payload.error) {
            reject(payload.error);
            return;
          }
          resolve(payload.data);
        });
    } catch (err) {
      console.error(`[workerExec] Error emitting command: ${command}`, err);
      reject(err);
    }
  });
}
