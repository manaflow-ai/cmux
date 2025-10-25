import { spawn } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { dirname } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

type CommandResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

type MaintenanceSummary = {
  ran: boolean;
  exitCode?: number;
  error?: string;
};

type DevSummary = {
  ran: boolean;
  started?: boolean;
  error?: string;
};

type Summary = {
  maintenance: MaintenanceSummary;
  dev: DevSummary;
  fatalError?: string;
};

type Config = {
  session: string;
  maintenanceWindow?: string;
  maintenanceScript?: string;
  maintenanceExitCode?: string;
  devWindow?: string;
  devScript?: string;
  logPath: string;
};

const DEFAULT_SESSION = "cmux";
const DEFAULT_LOG_PATH = "/var/log/cmux/start-dev-maintenance.log";
const MAINTENANCE_EXIT_CODE_WAIT_MS = 1000;
const MAINTENANCE_EXIT_CODE_MAX_ATTEMPTS = 7200;
const TMUX_WAIT_ATTEMPTS = 40;
const TMUX_WAIT_DELAY_MS = 500;

function parseArgs(): Config {
  const args = process.argv.slice(2);
  const config: Config = {
    session: DEFAULT_SESSION,
    logPath: DEFAULT_LOG_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const current = args[index];
    if (!current) {
      continue;
    }
    const next = args[index + 1];
    switch (current) {
      case "--session": {
        if (next) {
          config.session = next;
          index += 1;
        }
        break;
      }
      case "--maintenance-window": {
        if (next) {
          config.maintenanceWindow = next;
          index += 1;
        }
        break;
      }
      case "--maintenance-script": {
        if (next) {
          config.maintenanceScript = next;
          index += 1;
        }
        break;
      }
      case "--maintenance-exit-code": {
        if (next) {
          config.maintenanceExitCode = next;
          index += 1;
        }
        break;
      }
      case "--dev-window": {
        if (next) {
          config.devWindow = next;
          index += 1;
        }
        break;
      }
      case "--dev-script": {
        if (next) {
          config.devScript = next;
          index += 1;
        }
        break;
      }
      case "--log-path": {
        if (next) {
          config.logPath = next;
          index += 1;
        }
        break;
      }
      default: {
        break;
      }
    }
  }

  return config;
}

function shQuote(value: string): string {
  return "'" + value.replace(/'/g, "'\\''") + "'";
}

function joinOutputs(result: CommandResult): string {
  const segments: string[] = [];
  if (result.stderr) {
    segments.push(`stderr: ${result.stderr}`);
  }
  if (result.stdout) {
    segments.push(`stdout: ${result.stdout}`);
  }
  return segments.join(" | ");
}

function appendLog(logPath: string, level: "INFO" | "ERROR", message: string): void {
  const timestamp = new Date().toISOString();
  const line = `[${timestamp}] [${level}] ${message}\n`;
  try {
    mkdirSync(dirname(logPath), { recursive: true });
    appendFileSync(logPath, line, { encoding: "utf8" });
  } catch (error) {
    const text = error instanceof Error ? error.message : String(error);
    console.error(`[ERROR] Failed to write log file ${logPath}: ${text}`);
  }
}

function logInfo(logPath: string, message: string): void {
  appendLog(logPath, "INFO", message);
  console.error(`[INFO] ${message}`);
}

function logError(logPath: string, message: string): void {
  appendLog(logPath, "ERROR", message);
  console.error(`[ERROR] ${message}`);
}

async function runCommand(args: string[]): Promise<CommandResult> {
  return new Promise((resolve) => {
    if (args.length === 0) {
      resolve({ exitCode: 1, stdout: "", stderr: "Empty command" });
      return;
    }

    const [command, ...rest] = args;
    const child = spawn(command, rest, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });

    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    child.on("error", (error: unknown) => {
      if (settled) {
        return;
      }
      settled = true;
      const message = error instanceof Error ? error.message : String(error);
      resolve({
        exitCode: 1,
        stdout: stdout.trim(),
        stderr: (stderr + (stderr ? "\n" : "") + message).trim(),
      });
    });

    child.on("close", (code: number | null) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve({
        exitCode: code ?? 0,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
      });
    });
  });
}

async function waitForTmuxSession(session: string, logPath: string): Promise<boolean> {
  for (let attempt = 0; attempt < TMUX_WAIT_ATTEMPTS; attempt += 1) {
    const result = await runCommand(["tmux", "has-session", "-t", session]);
    if (result.exitCode === 0) {
      return true;
    }
    await delay(TMUX_WAIT_DELAY_MS);
  }

  logError(logPath, `tmux session '${session}' not found after waiting`);
  return false;
}

async function waitForExitCode(path: string, logPath: string): Promise<number | null> {
  for (let attempt = 0; attempt < MAINTENANCE_EXIT_CODE_MAX_ATTEMPTS; attempt += 1) {
    if (existsSync(path)) {
      try {
        const raw = readFileSync(path, "utf8").trim();
        try {
          rmSync(path);
        } catch (removeError) {
          const err = removeError as NodeJS.ErrnoException;
          if (err && err.code !== "ENOENT") {
            logError(
              logPath,
              `Failed to remove maintenance exit code file ${path}: ${err.message ?? String(removeError)}`,
            );
          }
        }
        if (raw.length === 0) {
          return 0;
        }
        const parsed = Number.parseInt(raw, 10);
        if (Number.isNaN(parsed)) {
          logError(logPath, `Invalid maintenance exit code '${raw}' at ${path}`);
          return null;
        }
        return parsed;
      } catch (error) {
        const text = error instanceof Error ? error.message : String(error);
        logError(logPath, `Failed to read maintenance exit code file ${path}: ${text}`);
        return null;
      }
    }
    await delay(MAINTENANCE_EXIT_CODE_WAIT_MS);
  }

  logError(logPath, `Timed out waiting for maintenance exit code file ${path}`);
  return null;
}

async function main(): Promise<void> {
  const config = parseArgs();
  const summary: Summary = {
    maintenance: { ran: false },
    dev: { ran: false },
  };

  const logPath = config.logPath || DEFAULT_LOG_PATH;

  if (!config.maintenanceScript && !config.devScript) {
    const message = "No maintenance or dev script provided";
    logError(logPath, message);
    summary.fatalError = message;
    console.log(JSON.stringify(summary));
    return;
  }

  const session = config.session || DEFAULT_SESSION;
  logInfo(logPath, `Waiting for tmux session '${session}'`);
  const hasSession = await waitForTmuxSession(session, logPath);
  if (!hasSession) {
    summary.fatalError = `tmux session '${session}' not found`;
    console.log(JSON.stringify(summary));
    return;
  }
  logInfo(logPath, `Found tmux session '${session}'`);

  if (config.maintenanceScript) {
    summary.maintenance.ran = true;
    const windowName = config.maintenanceWindow ?? "maintenance";
    const exitCodePath = config.maintenanceExitCode;

    if (!exitCodePath) {
      const message = "Maintenance exit code path is missing";
      logError(logPath, message);
      summary.maintenance.error = message;
    } else {
      logInfo(logPath, `Starting maintenance window '${windowName}'`);
      try {
        rmSync(exitCodePath);
      } catch (error) {
        const err = error as NodeJS.ErrnoException;
        if (err && err.code !== "ENOENT") {
          logError(logPath, `Failed to clear maintenance exit code file ${exitCodePath}: ${err.message ?? String(error)}`);
        }
      }

      const newWindowResult = await runCommand([
        "tmux",
        "new-window",
        "-t",
        `${session}:`,
        "-n",
        windowName,
        "-d",
      ]);

      if (newWindowResult.exitCode !== 0) {
        const message = `tmux new-window for maintenance failed (${joinOutputs(newWindowResult)})`;
        logError(logPath, message);
        summary.maintenance.error = message;
      } else {
        const commandSegments = [
          `zsh ${shQuote(config.maintenanceScript)}`,
          "EXIT_CODE=$?",
          `echo "$EXIT_CODE" > ${shQuote(exitCodePath)}`,
          `if [ "$EXIT_CODE" -ne 0 ]; then`,
          `echo "[MAINTENANCE] Script exited with code $EXIT_CODE" >&2`,
          "else",
          `echo "[MAINTENANCE] Script completed successfully"`,
          "fi",
          "exec zsh",
        ];
        const runCommandText = commandSegments.join("; ");

        const sendKeysResult = await runCommand([
          "tmux",
          "send-keys",
          "-t",
          `${session}:${windowName}`,
          runCommandText,
          "C-m",
        ]);

        if (sendKeysResult.exitCode !== 0) {
          const message = `tmux send-keys for maintenance failed (${joinOutputs(sendKeysResult)})`;
          logError(logPath, message);
          summary.maintenance.error = message;
        } else {
          const exitCode = await waitForExitCode(exitCodePath, logPath);
          if (exitCode === null) {
            const message = `Maintenance script did not report an exit code via ${exitCodePath}`;
            logError(logPath, message);
            summary.maintenance.error = message;
          } else {
            summary.maintenance.exitCode = exitCode;
            if (exitCode !== 0) {
              const message = `Maintenance script exited with code ${exitCode}`;
              logError(logPath, message);
              summary.maintenance.error = message;
            } else {
              logInfo(logPath, "Maintenance script completed successfully");
            }
          }
        }
      }
    }
  }

  if (config.devScript) {
    summary.dev.ran = true;
    const devWindow = config.devWindow ?? "dev";
    logInfo(logPath, `Starting dev window '${devWindow}'`);

    const newWindowResult = await runCommand([
      "tmux",
      "new-window",
      "-t",
      `${session}:`,
      "-n",
      devWindow,
      "-d",
    ]);

    if (newWindowResult.exitCode !== 0) {
      const message = `tmux new-window for dev failed (${joinOutputs(newWindowResult)})`;
      logError(logPath, message);
      summary.dev.error = message;
    } else {
      const sendKeysResult = await runCommand([
        "tmux",
        "send-keys",
        "-t",
        `${session}:${devWindow}`,
        `zsh ${shQuote(config.devScript)}`,
        "C-m",
      ]);

      if (sendKeysResult.exitCode !== 0) {
        const message = `tmux send-keys for dev failed (${joinOutputs(sendKeysResult)})`;
        logError(logPath, message);
        summary.dev.error = message;
      } else {
        await delay(2000);
        const listResult = await runCommand(["tmux", "list-windows", "-t", session]);
        if (listResult.exitCode !== 0) {
          const message = `tmux list-windows failed when verifying dev window (${joinOutputs(listResult)})`;
          logError(logPath, message);
          summary.dev.error = message;
        } else {
          const windowLines = listResult.stdout
            .split("\n")
            .map((line) => line.trim())
            .filter(Boolean);
          const found = windowLines.some((line) => {
            const parts = line.split(":");
            if (parts.length < 2) {
              return false;
            }
            const namePart = parts[1]?.trim() ?? "";
            return namePart.startsWith(devWindow);
          });
          if (!found) {
            const message = `Dev window '${devWindow}' not found after start`;
            logError(logPath, message);
            summary.dev.error = message;
          } else {
            summary.dev.started = true;
            logInfo(logPath, `Dev window '${devWindow}' started`);
          }
        }
      }
    }
  }

  console.log(JSON.stringify(summary));
}

void main();
