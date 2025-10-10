import type { WorkerToServerEvents } from "@cmux/shared";
import { serverLogger } from "./utils/fileLogger";
import type { VSCodeInstance } from "./vscode/VSCodeInstance";

type WorkerSocket = ReturnType<VSCodeInstance["getWorkerSocket"]>;
type TerminalOutputEvent = Parameters<
  WorkerToServerEvents["worker:terminal-output"]
>[0];

/**
 * Capture git diff by running commands in the VSCode terminal
 * This ensures we're in the same environment where the agent made changes
 */
export async function captureGitDiffViaTerminal(
  vscodeInstance: VSCodeInstance,
  worktreePath: string,
  originalTerminalId: string
): Promise<string> {
  try {
    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      serverLogger.error(`[GitDiffCapture] No worker connection`);
      return "";
    }

    serverLogger.info(
      `[GitDiffCapture] ========================================`
    );
    serverLogger.info(
      `[GitDiffCapture] CAPTURING GIT DIFF VIA VSCODE TERMINAL`
    );
    serverLogger.info(`[GitDiffCapture] Using terminal: ${originalTerminalId}`);
    serverLogger.info(`[GitDiffCapture] Working directory: ${worktreePath}`);
    serverLogger.info(
      `[GitDiffCapture] ========================================`
    );

    // Collect terminal output
    let terminalOutput = "";
    let isCapturing = false;
    let captureMarker = `===GIT_DIFF_CAPTURE_${Date.now()}===`;

    // Set up output listener
    const outputHandler = (data: TerminalOutputEvent) => {
      serverLogger.info(`[GitDiffCapture] Received terminal output event:`, {
        terminalId: data.terminalId,
        expectedId: originalTerminalId,
        dataLength: data.data?.length || 0,
        isCapturing,
        hasMarker: data.data?.includes(captureMarker) || false,
      });

      if (data.terminalId === originalTerminalId && data.data) {
        if (data.data.includes(captureMarker)) {
          isCapturing = true;
          terminalOutput = ""; // Reset when we see the marker
          serverLogger.info(`[GitDiffCapture] Started capturing after marker`);
        } else if (isCapturing) {
          terminalOutput += data.data;
          serverLogger.info(
            `[GitDiffCapture] Captured ${data.data.length} chars, total: ${terminalOutput.length}`
          );
        }
      }
    };

    workerSocket.on("worker:terminal-output", outputHandler);

    try {
      // Send marker to know when to start capturing
      await sendTerminalCommand(
        workerSocket,
        originalTerminalId,
        `echo "${captureMarker}"`
      );
      await new Promise((resolve) => setTimeout(resolve, 500));

      // Run git add .
      serverLogger.info(`[GitDiffCapture] Running 'git add .' in terminal`);
      await sendTerminalCommand(workerSocket, originalTerminalId, "git add .");
      await new Promise((resolve) => setTimeout(resolve, 2000)); // Wait for git to process

      // Run git diff HEAD as user requested
      serverLogger.info(`[GitDiffCapture] Running 'git diff HEAD' in terminal`);
      await sendTerminalCommand(
        workerSocket,
        originalTerminalId,
        "git diff HEAD"
      );
      await new Promise((resolve) => setTimeout(resolve, 5000)); // Wait for diff output

      // Stop capturing
      isCapturing = false;

      // Clean the output
      let cleanedDiff = cleanTerminalOutput(terminalOutput);

      serverLogger.info(
        `[GitDiffCapture] Raw terminal output length: ${terminalOutput.length}`
      );
      serverLogger.info(
        `[GitDiffCapture] First 200 chars of raw output: ${terminalOutput.substring(0, 200)}`
      );
      serverLogger.info(
        `[GitDiffCapture] Cleaned diff length: ${cleanedDiff.length}`
      );

      if (!cleanedDiff || cleanedDiff.length < 10) {
        serverLogger.warn(
          `[GitDiffCapture] No diff captured, trying alternative approach`
        );

        // Try with explicit output redirection
        terminalOutput = "";
        isCapturing = true;

        await sendTerminalCommand(
          workerSocket,
          originalTerminalId,
          `echo "${captureMarker}"`
        );
        await new Promise((resolve) => setTimeout(resolve, 500));

        // Try git diff HEAD instead
        await sendTerminalCommand(
          workerSocket,
          originalTerminalId,
          "git diff HEAD"
        );
        await new Promise((resolve) => setTimeout(resolve, 5000));

        cleanedDiff = cleanTerminalOutput(terminalOutput);
        serverLogger.info(
          `[GitDiffCapture] Alternative approach - raw output length: ${terminalOutput.length}`
        );
        serverLogger.info(
          `[GitDiffCapture] Alternative approach - cleaned diff length: ${cleanedDiff.length}`
        );
      }

      serverLogger.info(
        `[GitDiffCapture] Captured diff length: ${cleanedDiff.length}`
      );
      return cleanedDiff || "No changes detected";
    } finally {
      // Clean up listener
      workerSocket.off("worker:terminal-output", outputHandler);
    }
  } catch (error) {
    serverLogger.error(`[GitDiffCapture] Error:`, error);
    return "";
  }
}

/**
 * Send a command to the terminal
 */
async function sendTerminalCommand(
  workerSocket: WorkerSocket,
  terminalId: string,
  command: string
): Promise<void> {
  return new Promise((resolve) => {
    workerSocket.emit("worker:terminal-input", {
      terminalId,
      data: command + "\n",
    });
    // Give it time to process
    setTimeout(resolve, 100);
  });
}

/**
 * Clean terminal output to extract just the git diff
 */
function cleanTerminalOutput(output: string): string {
  if (!output) return "";

  // Split into lines and filter out terminal noise
  const lines = output.split("\n");
  const cleanedLines: string[] = [];
  let inDiff = false;

  for (const line of lines) {
    // Skip terminal prompts and echo commands
    if (
      line.includes("root@") ||
      line.includes("git add") ||
      line.includes("git diff") ||
      line.includes("echo ") ||
      line.includes("GIT_DIFF_CAPTURE")
    ) {
      continue;
    }

    // Detect start of diff
    if (
      line.startsWith("diff --git") ||
      line.startsWith("index ") ||
      line.startsWith("---") ||
      line.startsWith("+++")
    ) {
      inDiff = true;
    }

    // Collect diff lines
    if (inDiff || line.startsWith("diff --git")) {
      cleanedLines.push(line);
    }
  }

  return cleanedLines.join("\n").trim();
}
