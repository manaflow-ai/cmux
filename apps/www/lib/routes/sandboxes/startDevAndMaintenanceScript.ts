import { z } from "zod";
import type { MorphInstance } from "./git";
import { singleQuote } from "./shell";

const WORKSPACE_ROOT = "/root/workspace";
const CMUX_RUNTIME_DIR = "/var/tmp/cmux-scripts";
const MAINTENANCE_WINDOW_NAME = "maintenance";
const MAINTENANCE_SCRIPT_FILENAME = "maintenance.sh";
const DEV_WINDOW_NAME = "dev";
const DEV_SCRIPT_FILENAME = "dev.sh";

export type ScriptIdentifiers = {
  maintenance: {
    windowName: string;
    scriptPath: string;
  };
  dev: {
    windowName: string;
    scriptPath: string;
  };
};

const orchestratorScriptConfigSchema = z.object({
  workspaceRoot: z.string(),
  runtimeDir: z.string(),
  maintenanceScriptPath: z.string(),
  devScriptPath: z.string(),
  maintenanceWindowName: z.string(),
  devWindowName: z.string(),
  maintenanceExitCodePath: z.string(),
  maintenanceErrorLogPath: z.string(),
  devExitCodePath: z.string(),
  devErrorLogPath: z.string(),
  hasMaintenanceScript: z.boolean(),
  hasDevScript: z.boolean(),
  convexUrl: z.string(),
  taskRunJwt: z.string(),
});

type OrchestratorScriptConfig = z.infer<typeof orchestratorScriptConfigSchema>;

export const allocateScriptIdentifiers = (): ScriptIdentifiers => {
  return {
    maintenance: {
      windowName: MAINTENANCE_WINDOW_NAME,
      scriptPath: `${CMUX_RUNTIME_DIR}/${MAINTENANCE_SCRIPT_FILENAME}`,
    },
    dev: {
      windowName: DEV_WINDOW_NAME,
      scriptPath: `${CMUX_RUNTIME_DIR}/${DEV_SCRIPT_FILENAME}`,
    },
  };
};

const buildOrchestratorScript = (
  config: OrchestratorScriptConfig,
): string => {
  const parsedConfig = orchestratorScriptConfigSchema.safeParse(config);
  if (!parsedConfig.success) {
    throw new Error(
      `Failed to generate orchestrator script: ${parsedConfig.error.message}`,
    );
  }

  const literal = (value: string): string => JSON.stringify(value);

  const {
    workspaceRoot,
    runtimeDir,
    maintenanceScriptPath,
    devScriptPath,
    maintenanceWindowName,
    devWindowName,
    maintenanceExitCodePath,
    maintenanceErrorLogPath,
    devExitCodePath,
    devErrorLogPath,
    hasMaintenanceScript,
    hasDevScript,
    convexUrl,
    taskRunJwt,
  } = parsedConfig.data;

  return `#!/usr/bin/env bun
/**
 * Orchestrator script for running maintenance and dev scripts in sequence.
 * This script runs in the background to avoid Vercel timeouts.
 *
 * Flow:
 * 1. Create both tmux windows upfront
 * 2. Run maintenance script and wait for completion
 * 3. Run dev script (regardless of maintenance outcome)
 */

import { $ } from "bun";

const WORKSPACE_ROOT = ${literal(workspaceRoot)};
const CMUX_RUNTIME_DIR = ${literal(runtimeDir)};
const MAINTENANCE_SCRIPT_PATH = ${literal(maintenanceScriptPath)};
const DEV_SCRIPT_PATH = ${literal(devScriptPath)};
const MAINTENANCE_WINDOW_NAME = ${literal(maintenanceWindowName)};
const DEV_WINDOW_NAME = ${literal(devWindowName)};
const MAINTENANCE_EXIT_CODE_PATH = ${literal(maintenanceExitCodePath)};
const MAINTENANCE_ERROR_LOG_PATH = ${literal(maintenanceErrorLogPath)};
const DEV_EXIT_CODE_PATH = ${literal(devExitCodePath)};
const DEV_ERROR_LOG_PATH = ${literal(devErrorLogPath)};
const HAS_MAINTENANCE_SCRIPT = ${hasMaintenanceScript};
const HAS_DEV_SCRIPT = ${hasDevScript};
const CONVEX_URL = ${literal(convexUrl)};
const TASK_RUN_JWT = ${literal(taskRunJwt)};

async function waitForTmuxSession(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try {
      const result = await $\`tmux has-session -t cmux 2>/dev/null\`.quiet();
      if (result.exitCode === 0) {
        console.log("[ORCHESTRATOR] tmux session found");
        return;
      }
    } catch (error) {
      // Session not ready yet
    }
    await Bun.sleep(500);
  }

  const result = await $\`tmux has-session -t cmux 2>/dev/null\`.quiet();
  if (result.exitCode !== 0) {
    throw new Error("Error: cmux session does not exist");
  }
}

async function createWindows(): Promise<void> {
  await waitForTmuxSession();

  if (HAS_MAINTENANCE_SCRIPT) {
    try {
      console.log(\`[ORCHESTRATOR] Creating \${MAINTENANCE_WINDOW_NAME} window...\`);
      await $\`tmux new-window -t cmux: -n \${MAINTENANCE_WINDOW_NAME} -d\`;
      console.log(\`[ORCHESTRATOR] \${MAINTENANCE_WINDOW_NAME} window created\`);
    } catch (error) {
      console.error(\`[ORCHESTRATOR] Failed to create \${MAINTENANCE_WINDOW_NAME} window:\`, error);
      throw error;
    }
  }

  if (HAS_DEV_SCRIPT) {
    try {
      console.log(\`[ORCHESTRATOR] Creating \${DEV_WINDOW_NAME} window...\`);
      await $\`tmux new-window -t cmux: -n \${DEV_WINDOW_NAME} -d\`;
      console.log(\`[ORCHESTRATOR] \${DEV_WINDOW_NAME} window created\`);
    } catch (error) {
      console.error(\`[ORCHESTRATOR] Failed to create \${DEV_WINDOW_NAME} window:\`, error);
      throw error;
    }
  }
}

async function runMaintenanceScript(): Promise<{ exitCode: number; error: string | null }> {
  if (!HAS_MAINTENANCE_SCRIPT) {
    console.log("[MAINTENANCE] No maintenance script to run");
    return { exitCode: 0, error: null };
  }

  try {
    console.log("[MAINTENANCE] Starting maintenance script...");

    // Run the script, capture exit code, then exec into new shell
    await $\`tmux send-keys -t cmux:\${MAINTENANCE_WINDOW_NAME} "zsh '\${MAINTENANCE_SCRIPT_PATH}' 2>&1 | tee '\${MAINTENANCE_ERROR_LOG_PATH}'; echo \\\${pipestatus[1]} > '\${MAINTENANCE_EXIT_CODE_PATH}'; exec zsh" C-m\`;

    await Bun.sleep(2000);

    console.log("[MAINTENANCE] Waiting for script to complete...");
    let attempts = 0;
    const maxAttempts = 600; // 10 minutes max
    while (attempts < maxAttempts) {
      const file = Bun.file(MAINTENANCE_EXIT_CODE_PATH);
      if (await file.exists()) {
        break;
      }
      await Bun.sleep(1000);
      attempts++;
    }

    if (attempts >= maxAttempts) {
      console.error("[MAINTENANCE] Script timed out after 10 minutes");
      return {
        exitCode: 124,
        error: "Maintenance script timed out after 10 minutes"
      };
    }

    const exitCodeFile = Bun.file(MAINTENANCE_EXIT_CODE_PATH);
    const exitCodeText = await exitCodeFile.text();
    const exitCodeRaw = exitCodeText.trim();
    const exitCode = Number.parseInt(exitCodeRaw, 10);

    await $\`rm -f \${MAINTENANCE_EXIT_CODE_PATH}\`;

    if (Number.isNaN(exitCode)) {
      console.error(\`[MAINTENANCE] Invalid exit code value: \${exitCodeRaw}\`);
      return {
        exitCode: 1,
        error: "Maintenance script exit code missing or invalid",
      };
    }

    console.log(\`[MAINTENANCE] Script completed with exit code \${exitCode}\`);

    if (exitCode !== 0) {
      // Read the error log to get actual error details
      let errorDetails = "";
      try {
        const errorLogFile = Bun.file(MAINTENANCE_ERROR_LOG_PATH);
        if (await errorLogFile.exists()) {
          const logContent = await errorLogFile.text();
          // Get the last 100 lines of output to capture the command and error context
          const lines = logContent.trim().split("\\n");
          const relevantLines = lines.slice(-100);
          errorDetails = relevantLines.join("\\n");
        }
      } catch (logError) {
        console.error("[MAINTENANCE] Failed to read error log:", logError);
      }

      const errorMessage = errorDetails || \`Maintenance script failed with exit code \${exitCode}\`;

      return {
        exitCode,
        error: errorMessage
      };
    }

    return { exitCode: 0, error: null };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error(\`[MAINTENANCE] Error: \${errorMessage}\`);
    return {
      exitCode: 1,
      error: \`Maintenance script execution failed: \${errorMessage}\`
    };
  }
}

async function reportErrorToConvex(maintenanceError: string | null, devError: string | null): Promise<void> {
  if (!TASK_RUN_JWT || !CONVEX_URL) {
    console.log("[ORCHESTRATOR] Skipping Convex error reporting: missing configuration");
    return;
  }

  if (!maintenanceError && !devError) {
    console.log("[ORCHESTRATOR] No errors to report");
    return;
  }

  try {
    console.log("[ORCHESTRATOR] Reporting errors to Convex HTTP action...");

    const body: Record<string, string> = {};
    if (maintenanceError) {
      body.maintenanceError = maintenanceError;
    }
    if (devError) {
      body.devError = devError;
    }

    const response = await fetch(\`\${CONVEX_URL}/http/api/task-runs/report-environment-error\`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": \`Bearer \${TASK_RUN_JWT}\`,
      },
      body: JSON.stringify(body),
    });

    console.log(\`[ORCHESTRATOR] Convex response status: \${response.status}\`);

    if (!response.ok) {
      const errorText = await response.text();
      console.error(\`[ORCHESTRATOR] Failed to report errors to Convex: \${response.status}\`);
      console.error(\`[ORCHESTRATOR] Response body: \${errorText}\`);
    } else {
      const responseData = await response.text();
      console.log(\`[ORCHESTRATOR] Successfully reported errors to Convex: \${responseData}\`);
    }
  } catch (error) {
    console.error(\`[ORCHESTRATOR] Exception while reporting errors to Convex:\`, error);
  }
}

async function startDevScript(): Promise<{ error: string | null }> {
  if (!HAS_DEV_SCRIPT) {
    console.log("[DEV] No dev script to run");
    return { error: null };
  }

  try {
    console.log("[DEV] Starting dev script...");

    // Run the script and capture exit code (don't exec zsh after since dev script may be long-running)
    await $\`tmux send-keys -t cmux:\${DEV_WINDOW_NAME} "zsh '\${DEV_SCRIPT_PATH}' 2>&1 | tee '\${DEV_ERROR_LOG_PATH}'; echo \\\${pipestatus[1]} > '\${DEV_EXIT_CODE_PATH}'" C-m\`;

    await Bun.sleep(2000);

    const windowCheck = await $\`tmux list-windows -t cmux\`.text();
    if (!windowCheck.includes(DEV_WINDOW_NAME)) {
      const error = "Dev window not found after starting script";
      console.error(\`[DEV] ERROR: \${error}\`);
      return { error };
    }

    console.log("[DEV] Checking for early exit...");

    // Wait a bit for the script to potentially error out
    await Bun.sleep(5000);

    // Check if an exit code was written (indicating the script finished)
    const exitCodeFile = Bun.file(DEV_EXIT_CODE_PATH);
    if (await exitCodeFile.exists()) {
      const exitCodeText = await exitCodeFile.text();
      const exitCodeRaw = exitCodeText.trim();
      const exitCode = Number.parseInt(exitCodeRaw, 10);

      await $\`rm -f \${DEV_EXIT_CODE_PATH}\`;

      if (Number.isNaN(exitCode)) {
        console.error(\`[DEV] Invalid exit code value: \${exitCodeRaw}\`);
        return { error: "Dev script exit code missing or invalid" };
      }

      if (exitCode !== 0) {
        console.error(\`[DEV] Script exited early with code \${exitCode}\`);

        // Read the error log to get actual error details
        let errorDetails = "";
        try {
          const errorLogFile = Bun.file(DEV_ERROR_LOG_PATH);
          if (await errorLogFile.exists()) {
            const logContent = await errorLogFile.text();
            // Get the last 100 lines of output to capture the command and error context
            const lines = logContent.trim().split("\\n");
            const relevantLines = lines.slice(-100);
            errorDetails = relevantLines.join("\\n");
          }
        } catch (logError) {
          console.error("[DEV] Failed to read error log:", logError);
        }

      const errorMessage = errorDetails || \`Dev script failed with exit code \${exitCode}\`;

        return { error: errorMessage };
      }
    }

    console.log("[DEV] Script started successfully");
    return { error: null };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error(\`[DEV] Error: \${errorMessage}\`);
    return {
      error: \`Dev script execution failed: \${errorMessage}\`
    };
  }
}

(async () => {
  try {
    console.log("[ORCHESTRATOR] Starting orchestrator...");
    console.log(\`[ORCHESTRATOR] CONVEX_URL: \${CONVEX_URL}\`);
    console.log(\`[ORCHESTRATOR] TASK_RUN_JWT present: \${!!TASK_RUN_JWT}\`);

    await createWindows();

    const maintenanceResult = await runMaintenanceScript();
    if (maintenanceResult.error) {
      console.error(\`[ORCHESTRATOR] Maintenance completed with error: \${maintenanceResult.error}\`);
    } else {
      console.log("[ORCHESTRATOR] Maintenance completed successfully");
    }

    const devResult = await startDevScript();
    if (devResult.error) {
      console.error(\`[ORCHESTRATOR] Dev script failed: \${devResult.error}\`);
    } else {
      console.log("[ORCHESTRATOR] Dev script started successfully");
    }

    const hasError = Boolean(maintenanceResult.error || devResult.error);
    console.log(\`[ORCHESTRATOR] Checking if should report errors - maintenance: \${!!maintenanceResult.error}, dev: \${!!devResult.error}\`);
    if (hasError) {
      await reportErrorToConvex(maintenanceResult.error, devResult.error);
    } else {
      console.log("[ORCHESTRATOR] No errors to report");
    }

    if (hasError) {
      process.exit(1);
    }

    console.log("[ORCHESTRATOR] Orchestrator completed successfully");
    process.exit(0);
  } catch (error) {
    console.error(\`[ORCHESTRATOR] Fatal error: \${error}\`);
    process.exit(1);
  }
})();
`;
};

export async function runMaintenanceAndDevScripts({
  instance,
  maintenanceScript,
  devScript,
  identifiers,
  convexUrl,
  taskRunJwt,
}: {
  instance: MorphInstance;
  maintenanceScript?: string;
  devScript?: string;
  identifiers?: ScriptIdentifiers;
  convexUrl?: string;
  taskRunJwt?: string;
}): Promise<void> {
  const ids = identifiers ?? allocateScriptIdentifiers();

  const hasMaintenanceScript = Boolean(
    maintenanceScript && maintenanceScript.trim().length > 0,
  );
  const hasDevScript = Boolean(devScript && devScript.trim().length > 0);

  if (!hasMaintenanceScript && !hasDevScript) {
    console.log("[runMaintenanceAndDevScripts] No maintenance or dev scripts provided; skipping start");
    return;
  }

  // Generate unique run IDs for this execution
  const runId = `${Date.now().toString(36)}_${Math.random()
    .toString(36)
    .slice(2, 10)}`;
  const orchestratorScriptPath = `${CMUX_RUNTIME_DIR}/orchestrator_${runId}.ts`;
  const maintenanceExitCodePath = `${CMUX_RUNTIME_DIR}/maintenance_${runId}.exit-code`;
  const maintenanceErrorLogPath = `${CMUX_RUNTIME_DIR}/maintenance_${runId}.log`;
  const devExitCodePath = `${CMUX_RUNTIME_DIR}/dev_${runId}.exit-code`;
  const devErrorLogPath = `${CMUX_RUNTIME_DIR}/dev_${runId}.log`;

  // Create maintenance script if provided
  const maintenanceScriptContent = hasMaintenanceScript
    ? `#!/bin/zsh
set -eux
cd ${WORKSPACE_ROOT}

echo "=== Maintenance Script Started at \\$(date) ==="
${maintenanceScript}
echo "=== Maintenance Script Completed at \\$(date) ==="
`
    : null;

  // Create dev script if provided
  const devScriptContent = hasDevScript
    ? `#!/bin/zsh
set -ux
cd ${WORKSPACE_ROOT}

echo "=== Dev Script Started at \\$(date) ==="
${devScript}
`
    : null;

  const orchestratorScript = buildOrchestratorScript({
    workspaceRoot: WORKSPACE_ROOT,
    runtimeDir: CMUX_RUNTIME_DIR,
    maintenanceScriptPath: ids.maintenance.scriptPath,
    devScriptPath: ids.dev.scriptPath,
    maintenanceWindowName: ids.maintenance.windowName,
    devWindowName: ids.dev.windowName,
    maintenanceExitCodePath,
    maintenanceErrorLogPath,
    devExitCodePath,
    devErrorLogPath,
    hasMaintenanceScript,
    hasDevScript,
    convexUrl: convexUrl ?? "",
    taskRunJwt: taskRunJwt ?? "",
  });

  // Create the command that sets up all scripts and starts the orchestrator in background
  const setupAndRunCommand = `set -eu
mkdir -p ${CMUX_RUNTIME_DIR}

# Write maintenance script if provided
${maintenanceScriptContent ? `cat > ${ids.maintenance.scriptPath} <<'MAINTENANCE_SCRIPT_EOF'
${maintenanceScriptContent}
MAINTENANCE_SCRIPT_EOF
chmod +x ${ids.maintenance.scriptPath}
rm -f ${maintenanceExitCodePath}` : ''}

# Write dev script if provided
${devScriptContent ? `cat > ${ids.dev.scriptPath} <<'DEV_SCRIPT_EOF'
${devScriptContent}
DEV_SCRIPT_EOF
chmod +x ${ids.dev.scriptPath}` : ''}

# Write orchestrator script
cat > ${orchestratorScriptPath} <<'ORCHESTRATOR_EOF'
${orchestratorScript}
ORCHESTRATOR_EOF
chmod +x ${orchestratorScriptPath}

# Start orchestrator as a background process (fire-and-forget)
# Redirect output to log file
nohup bun ${orchestratorScriptPath} > ${CMUX_RUNTIME_DIR}/orchestrator_${runId}.log 2>&1 &
ORCHESTRATOR_PID=$!

# Give it a moment to start
sleep 1

# Verify the process is still running
if kill -0 $ORCHESTRATOR_PID 2>/dev/null; then
  echo "[ORCHESTRATOR] Started successfully in background (PID: $ORCHESTRATOR_PID)"
else
  echo "[ORCHESTRATOR] ERROR: Process failed to start or exited immediately" >&2
  exit 1
fi
`;

  try {
    const result = await instance.exec(
      `zsh -lc ${singleQuote(setupAndRunCommand)}`,
    );

    const stdout = result.stdout?.trim() ?? "";
    const stderr = result.stderr?.trim() ?? "";

    if (result.exit_code !== 0) {
      const message =
        `Failed to start orchestrator: exit code ${result.exit_code}` +
        (stderr ? ` | stderr: ${stderr}` : "");
      throw new Error(message);
    }

    if (!stdout.includes("[ORCHESTRATOR] Started successfully in background (PID:")) {
      throw new Error("Orchestrator did not confirm successful start");
    }

    console.log(`[runMaintenanceAndDevScripts] Orchestrator started successfully`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[runMaintenanceAndDevScripts] Failed to start orchestrator: ${message}`);
    throw new Error(message);
  }
}
