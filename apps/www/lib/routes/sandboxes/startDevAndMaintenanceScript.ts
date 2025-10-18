import type { MorphInstance } from "./git";
import { singleQuote } from "./shell";

const WORKSPACE_ROOT = "/root/workspace";
const CMUX_RUNTIME_DIR = "/var/tmp/cmux-scripts";
const MAINTENANCE_WINDOW_NAME = "maintenance";
const MAINTENANCE_SCRIPT_FILENAME = "maintenance.sh";
const DEV_WINDOW_NAME = "dev";
const DEV_SCRIPT_FILENAME = "dev.sh";
const EXIT_CODE_POLL_INTERVAL_MS = 1_000;
const EXIT_CODE_MAX_ATTEMPTS = 1_800; // ~30 minutes

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

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

type ScriptResult = {
  maintenanceError: string | null;
  devError: string | null;
};

export async function runMaintenanceAndDevScripts({
  instance,
  maintenanceScript,
  devScript,
  identifiers,
}: {
  instance: MorphInstance;
  maintenanceScript?: string;
  devScript?: string;
  identifiers?: ScriptIdentifiers;
}): Promise<ScriptResult> {
  const ids = identifiers ?? allocateScriptIdentifiers();

  const maintenanceScriptBody = maintenanceScript ?? "";
  const devScriptBody = devScript ?? "";

  const hasMaintenanceScript = maintenanceScriptBody.trim().length > 0;
  const hasDevScript = devScriptBody.trim().length > 0;

  if (!hasMaintenanceScript && !hasDevScript) {
    return {
      maintenanceError: "Both maintenance and dev scripts are empty",
      devError: null,
    };
  }

  const waitForTmuxSession = `for i in {1..20}; do
  if tmux has-session -t cmux 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if ! tmux has-session -t cmux 2>/dev/null; then
  echo "Error: cmux session does not exist" >&2
  exit 1
fi`;

  let maintenanceError: string | null = null;
  let devError: string | null = null;

  let maintenanceExitCodePath: string | null = null;
  let maintenanceDoneFlagPath: string | null = null;
  let maintenanceRunId: string | null = null;
  let maintenanceStartSucceeded = false;

  if (hasMaintenanceScript) {
    maintenanceRunId = `maintenance_${Date.now().toString(36)}_${Math.random()
      .toString(36)
      .slice(2, 10)}`;
    maintenanceExitCodePath = `${ids.maintenance.scriptPath}.${maintenanceRunId}.exit-code`;
    maintenanceDoneFlagPath = `${maintenanceExitCodePath}.done`;

    const maintenanceScriptContent = `#!/bin/zsh
set -eux
cd ${WORKSPACE_ROOT}

EXIT_CODE_FILE="${maintenanceExitCodePath}"
DONE_FLAG_FILE="${maintenanceDoneFlagPath}"

echo "=== Maintenance Script Started at \\\$(date) ==="

set +e
(
${maintenanceScriptBody}
)
SCRIPT_EXIT_CODE=$?
set -e

echo "$SCRIPT_EXIT_CODE" > "$EXIT_CODE_FILE"
touch "$DONE_FLAG_FILE"

if [ "$SCRIPT_EXIT_CODE" -ne 0 ]; then
  echo "[MAINTENANCE] Script exited with code $SCRIPT_EXIT_CODE" >&2
else
  echo "[MAINTENANCE] Script completed successfully"
fi

echo "=== Maintenance Script Completed at \\\$(date) ==="
exit "$SCRIPT_EXIT_CODE"
`;

    const maintenanceWindowCommand = `zsh "${ids.maintenance.scriptPath}" || true
exec zsh`;

    const maintenanceCommand = `set -eu
mkdir -p ${CMUX_RUNTIME_DIR}
cat > ${ids.maintenance.scriptPath} <<'SCRIPT_EOF'
${maintenanceScriptContent}
SCRIPT_EOF
chmod +x ${ids.maintenance.scriptPath}
rm -f ${maintenanceExitCodePath}
rm -f ${maintenanceDoneFlagPath}
${waitForTmuxSession}
tmux kill-window -t cmux:${ids.maintenance.windowName} 2>/dev/null || true
tmux new-window -t cmux: -n ${ids.maintenance.windowName} -d ${singleQuote(
      maintenanceWindowCommand,
    )}
sleep 2
if tmux list-windows -t cmux | grep -q "${ids.maintenance.windowName}"; then
  echo "[MAINTENANCE] Window is running"
else
  echo "[MAINTENANCE] ERROR: Window not found" >&2
  exit 1
fi
`;

    try {
      const result = await instance.exec(
        `zsh -lc ${singleQuote(maintenanceCommand)}`,
      );

      if (result.exit_code !== 0) {
        const stderr = result.stderr?.trim() ?? "";
        const stdout = result.stdout?.trim() ?? "";
        const messageParts = [
          `Maintenance script launch exited with code ${result.exit_code}`,
          stderr.length > 0 ? `stderr: ${stderr}` : null,
          stdout.length > 0 ? `stdout: ${stdout}` : null,
        ].filter((part): part is string => part !== null);
        maintenanceError = messageParts.join(" | ");
      } else {
        maintenanceStartSucceeded = true;
        if (result.stdout && result.stdout.length > 0) {
          console.log(`[MAINTENANCE SCRIPT LAUNCH]\n${result.stdout}`);
        }
      }
    } catch (error) {
      maintenanceError = `Maintenance script execution failed: ${error instanceof Error ? error.message : String(error)}`;
    }
  }

  const maintenanceDoneFlagForDev =
    hasMaintenanceScript && maintenanceStartSucceeded && maintenanceDoneFlagPath
      ? maintenanceDoneFlagPath
      : "";

  if (hasDevScript) {
    const devScriptContent = `#!/bin/zsh
set -ux
cd ${WORKSPACE_ROOT}

MAINTENANCE_DONE_FILE="${maintenanceDoneFlagForDev}"

if [ -n "$MAINTENANCE_DONE_FILE" ]; then
  echo "[DEV] Waiting for maintenance script to complete..."
  while [ ! -f "$MAINTENANCE_DONE_FILE" ]; do
    sleep 1
  done
  echo "[DEV] Maintenance completed, starting dev script"
fi

echo "=== Dev Script Started at \\\$(date) ==="
${devScriptBody}
`;

    const devCommand = `set -eu
mkdir -p ${CMUX_RUNTIME_DIR}
cat > ${ids.dev.scriptPath} <<'SCRIPT_EOF'
${devScriptContent}
SCRIPT_EOF
chmod +x ${ids.dev.scriptPath}
${waitForTmuxSession}
tmux kill-window -t cmux:${ids.dev.windowName} 2>/dev/null || true
tmux new-window -t cmux: -n ${ids.dev.windowName} -d ${singleQuote(
      `zsh ${ids.dev.scriptPath}`,
    )}
sleep 2
if tmux list-windows -t cmux | grep -q "${ids.dev.windowName}"; then
  echo "[DEV] Window is running"
else
  echo "[DEV] ERROR: Window not found" >&2
  exit 1
fi
`;

    try {
      const result = await instance.exec(`zsh -lc ${singleQuote(devCommand)}`);

      if (result.exit_code !== 0) {
        const stderr = result.stderr?.trim() ?? "";
        const stdout = result.stdout?.trim() ?? "";
        const messageParts = [
          `Failed to start dev script with exit code ${result.exit_code}`,
          stderr.length > 0 ? `stderr: ${stderr}` : null,
          stdout.length > 0 ? `stdout: ${stdout}` : null,
        ].filter((part): part is string => part !== null);
        devError = messageParts.join(" | ");
      } else if (result.stdout && result.stdout.length > 0) {
        console.log(`[DEV SCRIPT LAUNCH]\n${result.stdout}`);
      }
    } catch (error) {
      devError = `Dev script execution failed: ${error instanceof Error ? error.message : String(error)}`;
    }
  }

  if (hasMaintenanceScript && maintenanceStartSucceeded && maintenanceExitCodePath) {
    const maintenanceExitCode = await (async (): Promise<number | null> => {
      for (let attempt = 0; attempt < EXIT_CODE_MAX_ATTEMPTS; attempt += 1) {
        try {
          const pollCommand = `if [ -f ${maintenanceExitCodePath} ]; then EXIT_CODE=$(cat ${maintenanceExitCodePath} || echo 0); rm -f ${maintenanceExitCodePath}; echo "EXIT_CODE:$EXIT_CODE"; else echo "PENDING"; fi`;
          const pollResult = await instance.exec(
            `zsh -lc ${singleQuote(pollCommand)}`,
          );

          const stdout = pollResult.stdout?.trim() ?? "";
          if (stdout.startsWith("EXIT_CODE:")) {
            const exitCodeString = stdout.slice("EXIT_CODE:".length).trim();
            const parsed = Number.parseInt(exitCodeString, 10);
            if (!Number.isNaN(parsed)) {
              return parsed;
            }
          }

          if (pollResult.stderr && pollResult.stderr.trim().length > 0) {
            console.error(
              `[MAINTENANCE] Poll stderr: ${pollResult.stderr.trim()}`,
            );
          }
        } catch (error) {
          console.error(
            `[MAINTENANCE] Failed to poll exit code (attempt ${attempt + 1}/${EXIT_CODE_MAX_ATTEMPTS})`,
            error,
          );
        }

        await sleep(EXIT_CODE_POLL_INTERVAL_MS);
      }

      return null;
    })();

    if (maintenanceExitCode === null) {
      const waitSeconds =
        (EXIT_CODE_POLL_INTERVAL_MS * EXIT_CODE_MAX_ATTEMPTS) / 1_000;
      if (maintenanceError === null) {
        maintenanceError = `Timed out waiting for maintenance script to finish after ${waitSeconds} seconds`;
      }
    } else if (maintenanceExitCode !== 0) {
      if (maintenanceError === null) {
        maintenanceError = `Maintenance script finished with exit code ${maintenanceExitCode}`;
      }
    } else {
      console.log(
        `[MAINTENANCE SCRIPT COMPLETED] run=${maintenanceRunId ?? "unknown"} exit=0`,
      );
    }
  }

  return {
    maintenanceError,
    devError,
  };
}
