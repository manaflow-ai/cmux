import { exec as childExec, execFile as childExecFile } from "node:child_process";
import { promisify } from "node:util";

export const WORKSPACE_ROOT =
  process.env.CMUX_WORKSPACE_PATH || "/root/workspace";

export const execAsync = promisify(childExec);
export const execFileAsync = promisify(childExecFile);

export interface CommandOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
}

export async function runCommandCapture(
  command: string,
  args: readonly string[],
  options: CommandOptions = {}
): Promise<string> {
  try {
    const { stdout } = await execFileAsync(command, args, {
      cwd: options.cwd,
      env: options.env,
    });
    return typeof stdout === "string" ? stdout : String(stdout);
  } catch (error) {
    const details =
      error && typeof error === "object" && "stderr" in error
        ? String(
            (error as { stderr?: string | Buffer | null }).stderr ?? ""
          ).trim()
        : "";
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    throw new Error(
      [
        `Command "${command} ${args.join(" ")}" failed: ${message}`,
        details ? `stderr: ${details}` : null,
      ]
        .filter(Boolean)
        .join(" | ")
    );
  }
}
