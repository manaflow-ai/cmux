import { promises as fs } from "node:fs";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import os from "node:os";
import { log } from "./logger.js";
// Dynamic imports for Node.js-specific modules
const getClaudeHelpers = async () => {
  const module = await import("@cmux/shared/src/providers/anthropic/completion-detector.ts");
  return {
    checkClaudeProjectFileCompletion: module.checkClaudeProjectFileCompletion,
    getClaudeProjectPath: module.getClaudeProjectPath
  };
};

// Codex (OpenAI) helpers
const getCodexHelpers = async () => {
  const module = await import("@cmux/shared/src/providers/openai/completion-detector.ts");
  return {
    checkCodexCompletionSince: module.checkCodexCompletionSince,
    didLatestSessionCompleteInTuiLog: module.didLatestSessionCompleteInTuiLog,
    getLatestCodexSessionIdSince: module.getLatestCodexSessionIdSince,
    findCodexRolloutPathForSession: module.findCodexRolloutPathForSession,
    checkCodexNotifyFileCompletion: module.checkCodexNotifyFileCompletion,
  };
};

// Gemini helpers
const getGeminiHelpers = async () => {
  const module = await import("@cmux/shared/src/providers/gemini/completion-detector.ts");
  return {
    getGeminiProjectPath: module.getGeminiProjectPath,
    checkGeminiProjectFileCompletion: module.checkGeminiProjectFileCompletion,
  };
};

// Other providers will be implemented with provider-specific detectors later


interface TaskCompletionOptions {
  taskId: string;
  agentType: "claude" | "codex" | "gemini" | "amp" | "opencode";
  workingDir: string;
  checkIntervalMs?: number;
  maxRuntimeMs?: number;
  minRuntimeMs?: number;
}

interface CompletionIndicator {
  stopReason?: string;
  status?: string;
  completed?: boolean;
}

export class TaskCompletionDetector extends EventEmitter {
  private checkInterval: NodeJS.Timeout | null = null;
  private startTime: number;
  private isRunning = false;

  constructor(private options: TaskCompletionOptions) {
    super();
    this.startTime = Date.now();
    this.options.checkIntervalMs = this.options.checkIntervalMs || 5000; // Check every 5 seconds
    this.options.maxRuntimeMs = this.options.maxRuntimeMs || 20 * 60 * 1000; // 20 minutes max
    this.options.minRuntimeMs = this.options.minRuntimeMs || 30000; // 30 seconds minimum
  }

  async start(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;
    
    log("INFO", `TaskCompletionDetector started for ${this.options.agentType} task ${this.options.taskId}`);

    this.checkInterval = setInterval(async () => {
      try {
        const isComplete = await this.checkCompletion();
        if (isComplete) {
          this.stop();
          this.emit("task-complete", {
            taskId: this.options.taskId,
            agentType: this.options.agentType,
            elapsedMs: Date.now() - this.startTime,
          });
        } else if (Date.now() - this.startTime > this.options.maxRuntimeMs!) {
          this.stop();
          this.emit("task-timeout", {
            taskId: this.options.taskId,
            agentType: this.options.agentType,
            elapsedMs: Date.now() - this.startTime,
          });
        }
      } catch (error) {
        log("ERROR", `Error checking task completion: ${error}`);
      }
    }, this.options.checkIntervalMs);
  }

  stop(): void {
    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }
    this.isRunning = false;
  }

  private async checkCompletion(): Promise<boolean> {
    // Don't consider task complete too early
    if (Date.now() - this.startTime < this.options.minRuntimeMs!) {
      return false;
    }

    switch (this.options.agentType) {
      case "claude":
        return await this.checkClaudeCompletion();
      case "codex":
        return await this.checkCodexCompletion();
      case "gemini":
        return await this.checkGeminiCompletion();
      case "amp":
        return await this.checkAmpCompletion();
      case "opencode":
        return await this.checkOpencodeCompletion();
      default:
        console.warn(`Unknown agent type: ${this.options.agentType}`);
        return false;
    }
  }

  private async checkClaudeCompletion(): Promise<boolean> {
    try {
      // Don't check for completion too early - Claude needs time to set up
      const elapsedTime = Date.now() - this.startTime;
      if (elapsedTime < this.options.minRuntimeMs!) {
        return false;
      }
      
      // Get the Claude helper functions
      const { getClaudeProjectPath, checkClaudeProjectFileCompletion } = await getClaudeHelpers();
      
      const projectDir = getClaudeProjectPath(this.options.workingDir);

      // Check if project directory exists
      try {
        await fs.access(projectDir);
      } catch {
        log("DEBUG", `Claude project directory not found: ${projectDir} - waiting for Claude to create it`);
        return false;
      }

      // Use the shared module to check completion with idle time requirement
      // Claude must be idle for at least 10 seconds to be considered complete
      const isComplete = await checkClaudeProjectFileCompletion(projectDir, undefined, 10000);
      
      if (isComplete) {
        log("INFO", `Claude task complete: detected completion pattern`);
        log("INFO", `Claude completion detected for project: ${projectDir}`);
        
        // Get the most recent JSONL file for logging
        const files = await fs.readdir(projectDir);
        const jsonlFiles = files
          .filter((f) => f.endsWith(".jsonl"))
          .sort((a, b) => b.localeCompare(a));
        
        if (jsonlFiles.length > 0) {
          const firstFile = jsonlFiles[0];
          if (firstFile) {
            const latestFile = path.join(projectDir, firstFile);
            log("INFO", `Completion detected in file: ${latestFile}`);
          }
        }
      }
      
      return isComplete;
    } catch (error) {
      log("ERROR", `Error checking Claude completion: ${error}`);
      return false;
    }
  }

  private async checkCodexCompletion(): Promise<boolean> {
    try {
      log("INFO", `[Codex Detector] Starting completion check for task ${this.options.taskId}`, {
        workingDir: this.options.workingDir,
        startTime: new Date(this.startTime).toISOString(),
        elapsedMs: Date.now() - this.startTime
      });
      
      // Notify-file based completion (no idleness): check codex-turns.jsonl
      const { checkCodexNotifyFileCompletion } = await getCodexHelpers();
      log("INFO", "[Codex Detector] Checking notify file for completion...");
      const notifyDone = await checkCodexNotifyFileCompletion(this.options.workingDir, this.startTime);
      
      if (notifyDone) {
        log("INFO", "Codex task complete via notify (agent-turn-complete)");
        return true;
      } else {
        log("DEBUG", "[Codex Detector] Notify file check returned false");
      }
      // Codex stores session logs in ~/.codex/sessions and codex-tui.log.
      // Use shared detector to find the session since this detector started,
      // then check whether the latest update_plan marks all steps completed.
      const { checkCodexCompletionSince } = await getCodexHelpers();
      log("INFO", "Invoking checkCodexCompletionSince", { since: this.startTime });
      const res = await checkCodexCompletionSince(this.startTime);
      if (res.isComplete) {
        log("INFO", `Codex task complete via ~/.codex rollout`, {
          sessionId: res.sessionId,
          rolloutPath: res.rolloutPath,
          plan: res.latestPlan,
        });
        return true;
      }

      // Extra debug logging when not complete
      const {
        didLatestSessionCompleteInTuiLog,
        getLatestCodexSessionIdSince,
        findCodexRolloutPathForSession,
      } = await getCodexHelpers();
      const tui = await didLatestSessionCompleteInTuiLog(this.startTime);
      const sessionId = tui?.sessionId || (await getLatestCodexSessionIdSince(this.startTime));
      const rolloutPath = sessionId
        ? await findCodexRolloutPathForSession(sessionId)
        : undefined;
      log("INFO", "Codex detector not complete yet", {
        tuiStatus: tui,
        sessionId,
        rolloutPath,
      });

      return false;
    } catch (error) {
      log("ERROR", `Error checking Codex completion: ${error}`);
      return false;
    }
  }

  private async checkGeminiCompletion(): Promise<boolean> {
    try {
      // Give Gemini some time to set up
      const elapsed = Date.now() - this.startTime;
      if (elapsed < this.options.minRuntimeMs!) return false;

      const { getGeminiProjectPath, checkGeminiProjectFileCompletion } = await getGeminiHelpers();
      const projectDir = getGeminiProjectPath(this.options.workingDir);

      // Ensure the project directory exists before checking
      try {
        await fs.access(projectDir);
      } catch {
        log("DEBUG", `Gemini project directory not found: ${projectDir}`);
        return false;
      }

      const isComplete = await checkGeminiProjectFileCompletion(projectDir, undefined, 10000);
      if (isComplete) {
        log("INFO", `Gemini task complete: detected completion pattern`);
        return true;
      }
      return false;
    } catch (error) {
      log("ERROR", `Error checking Gemini completion: ${error}`);
      return false;
    }
  }

  private async checkAmpCompletion(): Promise<boolean> {
    // TODO: Implement Amp-specific completion detection
    console.log("Amp completion detection not yet implemented");
    return false;
  }

  private async checkOpencodeCompletion(): Promise<boolean> {
    // TODO: Implement Opencode-specific completion detection
    console.log("Opencode completion detection not yet implemented");
    return false;
  }
}

// Fallback to terminal idle detection if project file detection fails
export async function detectTaskCompletionWithFallback(
  options: TaskCompletionOptions & {
    terminalId?: string;
    idleTimeoutMs?: number;
    onTerminalIdle?: () => void;
  }
): Promise<TaskCompletionDetector> {
  const detector = new TaskCompletionDetector(options);
  
  // Start the project file-based detection
  await detector.start();

  // If terminal ID is provided, also set up terminal idle detection as fallback
  if (options.terminalId && options.onTerminalIdle) {
    const { detectTerminalIdle } = await import("./detectTerminalIdle");
    
    detectTerminalIdle({
      sessionName: options.terminalId,
      idleTimeoutMs: options.idleTimeoutMs || 15000,
      onIdle: () => {
        log("INFO", "Terminal idle detected (fallback)");
        detector.stop();
        options.onTerminalIdle!();
      },
    });
  }

  return detector;
}
