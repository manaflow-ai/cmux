import { exec } from "node:child_process";
import { promisify } from "node:util";
import { dockerLogger } from "./fileLogger";

const execAsync = promisify(exec);

const PROTECTED_PROCESSES = [
  "orbstack",
  "com.orbstack",
  "Docker",
  "docker-desktop",
  "dockerd",
  "containerd",
  "systemd",
  "launchd",
  "kernel_task",
];

/**
 * Extract port number from Docker error messages.
 * Docker can return errors like:
 * - "Bind for 0.0.0.0:12345 failed: port is already allocated"
 * - "driver failed programming external connectivity ... bind: address already in use"
 */
export function extractPortFromError(errorMessage: string): number | null {
  // Match "Bind for 0.0.0.0:PORT" pattern
  const bindMatch = errorMessage.match(/Bind for [^:]+:(\d+)/);
  if (bindMatch?.[1]) {
    return parseInt(bindMatch[1], 10);
  }

  // Match ":PORT failed" pattern
  const portFailedMatch = errorMessage.match(/:(\d+) failed/);
  if (portFailedMatch?.[1]) {
    return parseInt(portFailedMatch[1], 10);
  }

  // Match "port PORT" pattern
  const portMatch = errorMessage.match(/port (\d+)/i);
  if (portMatch?.[1]) {
    return parseInt(portMatch[1], 10);
  }

  return null;
}

/**
 * Check if an error is a port conflict error.
 */
export function isPortConflictError(error: unknown): boolean {
  if (!error) return false;

  const errorMessage =
    error instanceof Error ? error.message : String(error);
  const lowerMessage = errorMessage.toLowerCase();

  return (
    lowerMessage.includes("port is already allocated") ||
    lowerMessage.includes("address already in use") ||
    lowerMessage.includes("bind: address already in use") ||
    (lowerMessage.includes("bind") && lowerMessage.includes("failed"))
  );
}

/**
 * Kill the process using a specific port.
 * Returns true if a process was killed, false otherwise.
 */
export async function killPort(port: number): Promise<boolean> {
  try {
    // Get detailed info about processes using this port
    const { stdout } = await execAsync(`lsof -n -i :${port} -P`);
    const lines = stdout.trim().split("\n").slice(1); // Skip header

    if (lines.length === 0 || !lines[0]) {
      dockerLogger.info(`[killPort] No process found on port ${port}`);
      return false;
    }

    let killedAny = false;

    for (const line of lines) {
      const parts = line.split(/\s+/);
      const command = parts[0];
      const pid = parts[1];

      if (!command || !pid) continue;

      // Check if this is a protected process
      const isProtected = PROTECTED_PROCESSES.some((proc) =>
        command.toLowerCase().includes(proc.toLowerCase())
      );

      if (isProtected) {
        dockerLogger.warn(
          `[killPort] Skipping protected process ${command} (PID ${pid}) on port ${port}`
        );
        continue;
      }

      try {
        dockerLogger.info(
          `[killPort] Killing process ${command} (PID ${pid}) on port ${port}`
        );

        // Try graceful shutdown first
        await execAsync(`kill -TERM ${pid}`);
        // Give it a moment to shut down
        await new Promise((resolve) => setTimeout(resolve, 100));

        // Check if still running
        try {
          await execAsync(`kill -0 ${pid}`);
          // If we get here, process is still running, force kill
          dockerLogger.info(
            `[killPort] Process ${pid} still running, sending SIGKILL`
          );
          await execAsync(`kill -9 ${pid}`);
        } catch {
          // Process already terminated
        }

        killedAny = true;
        dockerLogger.info(
          `[killPort] Successfully killed process on port ${port}`
        );
      } catch (killError) {
        dockerLogger.warn(
          `[killPort] Failed to kill process ${pid} on port ${port}:`,
          killError
        );
      }
    }

    // Wait a bit for the port to be released
    if (killedAny) {
      await new Promise((resolve) => setTimeout(resolve, 200));
    }

    return killedAny;
  } catch (error) {
    // lsof returns exit code 1 when no processes found
    dockerLogger.info(`[killPort] No process found on port ${port}`);
    return false;
  }
}

/**
 * Kill processes on multiple ports.
 * Returns the ports that had processes killed.
 */
export async function killPorts(ports: number[]): Promise<number[]> {
  const killedPorts: number[] = [];

  for (const port of ports) {
    const killed = await killPort(port);
    if (killed) {
      killedPorts.push(port);
    }
  }

  return killedPorts;
}
