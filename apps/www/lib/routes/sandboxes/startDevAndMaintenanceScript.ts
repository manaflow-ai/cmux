import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
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

const getOrchestratorScript = (): string => {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const scriptPath = join(
    __dirname,
    "devAndMaintenanceOrchestratorScript.ts",
  );
  return readFileSync(scriptPath, "utf-8");
};

export async function runMaintenanceAndDevScripts({
  instance,
  maintenanceScript,
  devScript,
  identifiers,
  convexUrl,
  taskRunJwt,
  isCloudWorkspace,
}: {
  instance: MorphInstance;
  maintenanceScript?: string;
  devScript?: string;
  identifiers?: ScriptIdentifiers;
  convexUrl?: string;
  taskRunJwt?: string;
  isCloudWorkspace?: boolean;
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
set -eu

# Source system profile for environment variables (RUSTUP_HOME, etc.)
# Use || true to ignore non-zero exit codes from nvm/etc that aren't real errors
[[ -f /etc/profile ]] && { source /etc/profile || true; }

# Load environment variables from envctl daemon (auto-starts daemon if needed)
# The daemon stores env vars set via 'envctl load' during sandbox startup
# Retry to handle daemon startup timing
__load_envctl_vars() {
  local max_attempts=15
  local attempt=0
  while (( attempt < max_attempts )); do
    local out
    if out="$(envctl export zsh --pwd "${WORKSPACE_ROOT}" 2>/dev/null)"; then
      eval "$out"
      return 0
    fi
    sleep 1
    (( attempt++ ))
  done
  echo "Warning: Could not load envctl environment variables after $max_attempts attempts" >&2
  return 0
}
__load_envctl_vars

cd ${WORKSPACE_ROOT}

echo "=== Maintenance Script Started at \\$(date) ==="
${maintenanceScript}
echo "=== Maintenance Script Completed at \\$(date) ==="
`
    : null;

  // Create dev script if provided
  const devScriptContent = hasDevScript
    ? `#!/bin/zsh
set -u

# Source system profile for environment variables (RUSTUP_HOME, etc.)
# Use || true to ignore non-zero exit codes from nvm/etc that aren't real errors
[[ -f /etc/profile ]] && { source /etc/profile || true; }

# Load environment variables from envctl daemon (auto-starts daemon if needed)
# The daemon stores env vars set via 'envctl load' during sandbox startup
# Retry to handle daemon startup timing
__load_envctl_vars() {
  local max_attempts=15
  local attempt=0
  while (( attempt < max_attempts )); do
    local out
    if out="$(envctl export zsh --pwd "${WORKSPACE_ROOT}" 2>/dev/null)"; then
      eval "$out"
      return 0
    fi
    sleep 1
    (( attempt++ ))
  done
  echo "Warning: Could not load envctl environment variables after $max_attempts attempts" >&2
  return 0
}
__load_envctl_vars

cd ${WORKSPACE_ROOT}

echo "=== Dev Script Started at \\$(date) ==="
${devScript}
`
    : null;

  const orchestratorScript = getOrchestratorScript();

  if (!convexUrl) {
    throw new Error("Convex URL not supplied but is required");
  }

  if (!taskRunJwt) {
    throw new Error("taskRunJwt not supplied but is required")
  }

  const orchestratorEnvVars: Record<string, string> = {
    CMUX_ORCH_WORKSPACE_ROOT: WORKSPACE_ROOT,
    CMUX_ORCH_RUNTIME_DIR: CMUX_RUNTIME_DIR,
    CMUX_ORCH_MAINTENANCE_SCRIPT_PATH: ids.maintenance.scriptPath,
    CMUX_ORCH_DEV_SCRIPT_PATH: ids.dev.scriptPath,
    CMUX_ORCH_MAINTENANCE_WINDOW_NAME: ids.maintenance.windowName,
    CMUX_ORCH_DEV_WINDOW_NAME: ids.dev.windowName,
    CMUX_ORCH_MAINTENANCE_EXIT_CODE_PATH: maintenanceExitCodePath,
    CMUX_ORCH_MAINTENANCE_ERROR_LOG_PATH: maintenanceErrorLogPath,
    CMUX_ORCH_DEV_EXIT_CODE_PATH: devExitCodePath,
    CMUX_ORCH_DEV_ERROR_LOG_PATH: devErrorLogPath,
    CMUX_ORCH_HAS_MAINTENANCE_SCRIPT: hasMaintenanceScript ? "1" : "0",
    CMUX_ORCH_HAS_DEV_SCRIPT: hasDevScript ? "1" : "0",
    CMUX_ORCH_CONVEX_URL: convexUrl,
    CMUX_ORCH_TASK_RUN_JWT: taskRunJwt,
    CMUX_ORCH_IS_CLOUD_WORKSPACE: isCloudWorkspace ? "1" : "0",
  };

  const orchestratorEnvString = Object.entries(orchestratorEnvVars)
    .map(([key, value]) => `export ${key}=${singleQuote(value)}`)
    .join("\n");

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

# Export orchestrator environment variables
${orchestratorEnvString}

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
