import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { MorphInstance } from "./git";
import { maskSensitive, singleQuote } from "./shell";

export interface HydrateRepoConfig {
  owner: string;
  name: string;
  repoFull: string;
  cloneUrl: string;
  maskedCloneUrl: string;
  depth: number;
  baseBranch: string;
  newBranch: string;
}

const MORPH_WORKSPACE_PATH = "/root/workspace";

const getHydrateScript = (): string => {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const scriptPath = join(__dirname, "hydrateRepoScript.ts");
  return readFileSync(scriptPath, "utf-8");
};

export const hydrateWorkspace = async ({
  instance,
  repo,
}: {
  instance: MorphInstance;
  repo?: HydrateRepoConfig;
}): Promise<void> => {
  const hydrateScript = getHydrateScript();

  // Create a temporary script file path
  const scriptPath = `/tmp/cmux-hydrate-${Date.now()}.ts`;

  // Build environment variables
  const envVars: Record<string, string> = {
    CMUX_WORKSPACE_PATH: MORPH_WORKSPACE_PATH,
    CMUX_DEPTH: String(repo?.depth || 1),
  };

  if (repo) {
    envVars.CMUX_OWNER = repo.owner;
    envVars.CMUX_REPO = repo.name;
    envVars.CMUX_REPO_FULL = repo.repoFull;
    envVars.CMUX_CLONE_URL = repo.cloneUrl;
    envVars.CMUX_MASKED_CLONE_URL = repo.maskedCloneUrl;
    envVars.CMUX_BASE_BRANCH = repo.baseBranch;
    envVars.CMUX_NEW_BRANCH = repo.newBranch;
  }

  // Build the command to write and execute the script
  const envString = Object.entries(envVars)
    .map(([key, value]) => `export ${key}=${singleQuote(value)}`)
    .join("\n");

  const command = `
set -e
${envString}
cat > ${scriptPath} << 'CMUX_HYDRATE_EOF'
${hydrateScript}
CMUX_HYDRATE_EOF
bun run ${scriptPath}
EXIT_CODE=$?
rm -f ${scriptPath}
exit $EXIT_CODE
`;

  console.log("[sandboxes.start] Starting hydration with Bun script");
  const hydrateRes = await instance.exec(`bash -c ${singleQuote(command)}`);

  // Log the full output for debugging
  const maskedStdout = maskSensitive(hydrateRes.stdout || "");
  const maskedStderr = maskSensitive(hydrateRes.stderr || "");

  if (maskedStdout) {
    console.log(
      `[sandboxes.start] hydration stdout:\n${maskedStdout.slice(0, 2000)}`
    );
  }

  if (maskedStderr) {
    console.log(
      `[sandboxes.start] hydration stderr:\n${maskedStderr.slice(0, 1000)}`
    );
  }

  console.log(`[sandboxes.start] hydration exit code: ${hydrateRes.exit_code}`);

  if (hydrateRes.exit_code !== 0) {
    throw new Error(`Hydration failed with exit code ${hydrateRes.exit_code}`);
  }
};

/**
 * Write sanitized shell history to the VM for zsh-autosuggestions.
 * Appends to ~/.zsh_history to preserve any existing history.
 */
export const writeShellHistory = async ({
  instance,
  sanitizedHistory,
}: {
  instance: MorphInstance;
  sanitizedHistory: string;
}): Promise<void> => {
  if (!sanitizedHistory || sanitizedHistory.trim().length === 0) {
    return;
  }

  console.log(
    `[sandboxes.start] Writing shell history (${sanitizedHistory.split("\n").length} lines)`,
  );

  // Use heredoc to safely write history content
  // Append (>>) to preserve any existing history in the VM
  const command = `
set -e
cat >> ~/.zsh_history << 'SHELL_HISTORY_EOF'
${sanitizedHistory}
SHELL_HISTORY_EOF
chmod 600 ~/.zsh_history
`;

  const result = await instance.exec(`bash -c ${singleQuote(command)}`);

  if (result.exit_code !== 0) {
    console.error(
      `[sandboxes.start] Failed to write shell history: exit=${result.exit_code} stderr=${(result.stderr || "").slice(0, 200)}`,
    );
    // Don't throw - this is a nice-to-have feature, not critical
  } else {
    console.log("[sandboxes.start] Shell history written successfully");
  }
};
