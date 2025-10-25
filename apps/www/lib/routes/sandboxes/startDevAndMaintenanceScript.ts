import { readFileSync } from "node:fs";

import type { MorphInstance } from "./git";
import { singleQuote } from "./shell";

const WORKSPACE_ROOT = "/root/workspace";
const CMUX_RUNTIME_DIR = "/var/tmp/cmux-scripts";
const MAINTENANCE_WINDOW_NAME = "maintenance";
const MAINTENANCE_SCRIPT_FILENAME = "maintenance.sh";
const DEV_WINDOW_NAME = "dev";
const DEV_SCRIPT_FILENAME = "dev.sh";
const ORCHESTRATOR_SCRIPT_FILENAME = "start-dev-maintenance.ts";
const ORCHESTRATOR_SCRIPT_PATH = `${CMUX_RUNTIME_DIR}/${ORCHESTRATOR_SCRIPT_FILENAME}`;
const TMUX_SESSION_NAME = "cmux";
const ORCHESTRATOR_LOG_PATH = "/var/log/cmux/start-dev-maintenance.log";

const ORCHESTRATOR_SCRIPT_SOURCE = readFileSync(
  new URL("./startDevMaintenanceOrchestrator.ts", import.meta.url),
  "utf8",
);
const ORCHESTRATOR_SCRIPT_CONTENT = `#!/usr/bin/env bun\n${ORCHESTRATOR_SCRIPT_SOURCE}`;

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

type OrchestratorSummary = {
  maintenance: {
    ran: boolean;
    exitCode?: number;
    error?: string;
  };
  dev: {
    ran: boolean;
    started?: boolean;
    error?: string;
  };
  fatalError?: string;
};

type ScriptResult = {
  maintenanceError: string | null;
  devError: string | null;
};

type ParsedSummary = {
  summary: OrchestratorSummary | null;
  parseError: string | null;
};

const parseOrchestratorOutput = (output: string): ParsedSummary => {
  const trimmed = output.trim();
  if (trimmed.length === 0) {
    return {
      summary: null,
      parseError: "Orchestrator script produced no output",
    };
  }

  const lines = trimmed
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const candidate = lines[index]!;
    try {
      const parsed = JSON.parse(candidate) as OrchestratorSummary;
      return { summary: parsed, parseError: null };
    } catch {
      continue;
    }
  }

  const exampleLine = lines.at(-1);
  return {
    summary: null,
    parseError: exampleLine
      ? `Failed to parse orchestrator output (example: ${exampleLine})`
      : "Failed to parse orchestrator output",
  };
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
  const trimmedMaintenance = maintenanceScript?.trim() ?? "";
  const trimmedDev = devScript?.trim() ?? "";
  const hasMaintenance = trimmedMaintenance.length > 0;
  const hasDev = trimmedDev.length > 0;

  if (!hasMaintenance && !hasDev) {
    return {
      maintenanceError: "Both maintenance and dev scripts are empty",
      devError: null,
    };
  }

  const ids = identifiers ?? allocateScriptIdentifiers();

  const commandLines: string[] = [
    "set -eu",
    `mkdir -p ${CMUX_RUNTIME_DIR}`,
  ];

  let maintenanceExitCodePath: string | undefined;

  if (hasMaintenance) {
    const maintenanceRunId = `maintenance_${Date.now().toString(36)}_${Math.random()
      .toString(36)
      .slice(2, 10)}`;
    maintenanceExitCodePath = `${ids.maintenance.scriptPath}.${maintenanceRunId}.exit-code`;

    const maintenanceScriptContent = `#!/bin/zsh\nset -eux\ncd ${WORKSPACE_ROOT}\n\necho "=== Maintenance Script Started at \\$(date) ==="\n${maintenanceScript ?? ""}\necho "=== Maintenance Script Completed at \\$(date) ==="\n`;

    commandLines.push(
      `cat > ${ids.maintenance.scriptPath} <<'MAINTENANCE_EOF'`,
      maintenanceScriptContent,
      "MAINTENANCE_EOF",
      `chmod +x ${ids.maintenance.scriptPath}`,
    );
  }

  if (hasDev) {
    const devScriptContent = `#!/bin/zsh\nset -ux\ncd ${WORKSPACE_ROOT}\n\necho "=== Dev Script Started at \\$(date) ==="\n${devScript ?? ""}\n`;

    commandLines.push(
      `cat > ${ids.dev.scriptPath} <<'DEV_EOF'`,
      devScriptContent,
      "DEV_EOF",
      `chmod +x ${ids.dev.scriptPath}`,
    );
  }

  commandLines.push(
    `cat > ${ORCHESTRATOR_SCRIPT_PATH} <<'ORCHESTRATOR_EOF'`,
    ORCHESTRATOR_SCRIPT_CONTENT,
    "ORCHESTRATOR_EOF",
    `chmod +x ${ORCHESTRATOR_SCRIPT_PATH}`,
  );

  const orchestratorArgs: string[] = [
    `--session ${singleQuote(TMUX_SESSION_NAME)}`,
    `--log-path ${singleQuote(ORCHESTRATOR_LOG_PATH)}`,
  ];

  if (hasMaintenance) {
    orchestratorArgs.push(
      `--maintenance-window ${singleQuote(ids.maintenance.windowName)}`,
      `--maintenance-script ${singleQuote(ids.maintenance.scriptPath)}`,
    );
    if (maintenanceExitCodePath) {
      orchestratorArgs.push(
        `--maintenance-exit-code ${singleQuote(maintenanceExitCodePath)}`,
      );
    }
  }

  if (hasDev) {
    orchestratorArgs.push(
      `--dev-window ${singleQuote(ids.dev.windowName)}`,
      `--dev-script ${singleQuote(ids.dev.scriptPath)}`,
    );
  }

  commandLines.push(
    `bun ${singleQuote(ORCHESTRATOR_SCRIPT_PATH)} ${orchestratorArgs.join(" ")}`,
  );

  const command = commandLines.join("\n");

  const result = await instance.exec(`zsh -lc ${singleQuote(command)}`);
  const stdout = result.stdout?.trim() ?? "";
  const stderr = result.stderr?.trim() ?? "";

  const { summary, parseError } = parseOrchestratorOutput(stdout);

  if (summary) {
    console.log("[startDevAndMaintenance] Orchestrator summary", summary);
  } else if (stdout.length > 0) {
    console.log(`[startDevAndMaintenance] Orchestrator stdout (unparsed): ${stdout}`);
  }

  if (stderr.length > 0) {
    console.error(`[startDevAndMaintenance] Orchestrator stderr: ${stderr}`);
  }

  const maintenanceErrors: string[] = [];
  const devErrors: string[] = [];

  if (result.exit_code !== 0) {
    const contextParts = [`exit code ${result.exit_code}`];
    if (stderr.length > 0) {
      contextParts.push(`stderr: ${stderr}`);
    }
    if (stdout.length > 0) {
      contextParts.push(`stdout: ${stdout}`);
    }
    const message = `[ORCHESTRATOR] ${contextParts.join(" | ")}`;
    if (hasMaintenance) {
      maintenanceErrors.push(message);
    }
    if (hasDev) {
      devErrors.push(message);
    }
  }

  if (summary) {
    if (summary.fatalError) {
      if (hasMaintenance) {
        maintenanceErrors.push(summary.fatalError);
      }
      if (hasDev) {
        devErrors.push(summary.fatalError);
      }
    }

    if (hasMaintenance) {
      if (summary.maintenance.error) {
        maintenanceErrors.push(summary.maintenance.error);
      }
      if (
        summary.maintenance.exitCode !== undefined &&
        summary.maintenance.exitCode !== 0 &&
        !summary.maintenance.error
      ) {
        maintenanceErrors.push(
          `Maintenance script exited with code ${summary.maintenance.exitCode}`,
        );
      }
    }

    if (hasDev) {
      if (summary.dev.error) {
        devErrors.push(summary.dev.error);
      }
      if (
        summary.dev.ran &&
        summary.dev.started === false &&
        !summary.dev.error
      ) {
        devErrors.push("Dev script did not start successfully");
      }
    }
  } else if (parseError) {
    const message =
      stdout.length > 0
        ? `${parseError}. Raw stdout: ${stdout}`
        : parseError;
    if (hasMaintenance) {
      maintenanceErrors.push(message);
    }
    if (hasDev) {
      devErrors.push(message);
    }
  }

  if (!summary && stderr.length > 0 && result.exit_code === 0) {
    const stderrMessage = `Orchestrator stderr: ${stderr}`;
    if (hasMaintenance) {
      maintenanceErrors.push(stderrMessage);
    }
    if (hasDev) {
      devErrors.push(stderrMessage);
    }
  }

  const maintenanceError = maintenanceErrors.length > 0 ? maintenanceErrors.join(" | ") : null;
  const devError = devErrors.length > 0 ? devErrors.join(" | ") : null;

  return {
    maintenanceError,
    devError,
  };
}
