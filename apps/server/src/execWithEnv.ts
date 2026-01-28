import { exec } from "node:child_process";
import { promisify } from "node:util";

// Helper to execute commands with inherited environment
const execAsync = promisify(exec);

/**
 * Escape a string for safe inclusion in single-quoted shell arguments.
 * In shell, to include a literal single quote inside single quotes,
 * you must: end the single-quoted string, add an escaped single quote,
 * and restart the single-quoted string. Example: ' becomes '\''
 *
 * SECURITY: This prevents shell injection when the command contains
 * user-controlled input with single quotes.
 */
export function escapeForSingleQuotes(str: string): string {
  // Replace each single quote with: end quote, escaped quote, start quote
  return str.replace(/'/g, "'\\''");
}

export const execWithEnv = (command: string) => {
  // SECURITY: Escape single quotes in the command to prevent shell injection.
  // Without this, a command like "echo 'foo'; malicious; echo '" would break
  // out of the quotes and execute arbitrary code.
  const escapedCommand = escapeForSingleQuotes(command);

  // Use zsh to ensure we get the user's shell environment and gh auth
  return execAsync(`/bin/zsh -c '${escapedCommand}'`, {
    env: {
      ...process.env,
    },
  });
};
