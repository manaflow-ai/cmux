import { serverLogger } from "./utils/fileLogger";
import { VSCodeInstance } from "./vscode/VSCodeInstance";
import type { Socket } from "@cmux/shared/socket";
import type { WorkerToServerEvents, ServerToWorkerEvents } from "@cmux/shared";

/**
 * Filter git diff output to remove changes from unnecessary files
 */
function filterGitDiff(diff: string): string {
  const lines = diff.split('\n');
  const filteredLines: string[] = [];
  let skipCurrentFile = false;
  
  // Patterns for files we want to exclude from the diff
  const excludeFilePatterns = [
    /^diff --git a\/.*\.lock\b/,
    /^diff --git a\/.*-lock\.(json|yaml|yml)\b/,
    /^diff --git a\/pnpm-lock\.yaml\b/,
    /^diff --git a\/yarn\.lock\b/,
    /^diff --git a\/package-lock\.json\b/,
    /^diff --git a\/Gemfile\.lock\b/,
    /^diff --git a\/poetry\.lock\b/,
    /^diff --git a\/Pipfile\.lock\b/,
    /^diff --git a\/composer\.lock\b/,
    /^diff --git a\/.*\.log\b/,
    /^diff --git a\/.*\.tmp\b/,
    /^diff --git a\/.*\.cache\b/,
    /^diff --git a\/\.DS_Store\b/,
    /^diff --git a\/node_modules\//,
    /^diff --git a\/dist\//,
    /^diff --git a\/build\//,
    /^diff --git a\/\.next\//,
    /^diff --git a\/out\//,
    /^diff --git a\/\.turbo\//,
    /^diff --git a\/coverage\//,
    /^diff --git a\/\.nyc_output\//,
    /^diff --git a\/.*\.min\.(js|css)\b/,
    /^diff --git a\/.*\.map\b/,
    /^diff --git a\/\.env\.local\b/,
    /^diff --git a\/\.env\..*\.local\b/
  ];
  
  for (const line of lines) {
    // Check if this is a new file diff header
    if (line.startsWith('diff --git')) {
      // Check if this file should be excluded
      skipCurrentFile = excludeFilePatterns.some(pattern => pattern.test(line));
      if (!skipCurrentFile) {
        filteredLines.push(line);
      }
    } else if (!skipCurrentFile) {
      // Include lines that are not part of a skipped file
      filteredLines.push(line);
    }
  }
  
  return filteredLines.join('\n');
}

/**
 * Helper to safely execute commands via socket with timeout handling
 */
async function safeSocketExec(
  workerSocket: Socket<WorkerToServerEvents, ServerToWorkerEvents>,
  command: string,
  args: string[],
  cwd: string,
  timeout: number = 5000
): Promise<{ success: boolean; stdout?: string; stderr?: string }> {
  return new Promise((resolve) => {
    try {
      workerSocket.timeout(timeout).emit(
        "worker:exec",
        {
          command,
          args,
          cwd,
          env: {},
        },
        (timeoutError, result) => {
          if (timeoutError) {
            if (timeoutError instanceof Error && timeoutError.message === "operation has timed out") {
              serverLogger.error(`[captureGitDiff] Socket timeout for command: ${command}`, timeoutError);
            } else {
              serverLogger.error(`[captureGitDiff] Error executing ${command}:`, timeoutError);
            }
            resolve({ success: false, stderr: "timeout" });
            return;
          }
          if (result?.error) {
            resolve({ success: false, stderr: String(result.error) });
            return;
          }
          resolve({
            success: true,
            stdout: result.data?.stdout || "",
            stderr: result.data?.stderr || "",
          });
        }
      );
    } catch (err) {
      serverLogger.error(`[captureGitDiff] Error emitting command ${command}:`, err);
      resolve({ success: false, stderr: "error" });
    }
  });
}

/**
 * Capture the full git diff including untracked files
 */
export async function captureGitDiff(
  vscodeInstance: VSCodeInstance,
  worktreePath: string
): Promise<string> {
  try {
    const workerSocket = vscodeInstance.getWorkerSocket();
    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      serverLogger.error(
        `[AgentSpawner] No worker connection for git diff capture`
      );
      return "";
    }

    serverLogger.info(
      `[AgentSpawner] ========================================`
    );
    serverLogger.info(`[AgentSpawner] STARTING GIT DIFF CAPTURE`);
    serverLogger.info(`[AgentSpawner] Local worktree path: ${worktreePath}`);
    serverLogger.info(`[AgentSpawner] Container workspace: /root/workspace`);
    serverLogger.info(
      `[AgentSpawner] ========================================`
    );

    // IMPORTANT: Use /root/workspace as the working directory, not the local filesystem path
    const containerWorkspace = "/root/workspace";

    // First check if we're in the right directory and git repo
    const pwdResult = await new Promise<{
      success: boolean;
      stdout?: string;
    }>((resolve) => {
      try {
        workerSocket.timeout(5000).emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "pwd && git rev-parse --show-toplevel"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError) {
              if (timeoutError instanceof Error && timeoutError.message === "operation has timed out") {
                serverLogger.error("[captureGitDiff] Socket timeout checking pwd", timeoutError);
              }
              resolve({ success: false });
              return;
            }
            if (result?.error) {
              resolve({ success: false });
              return;
            }
            resolve({
              success: true,
              stdout: result.data?.stdout || "",
            });
          }
        );
      } catch (err) {
        serverLogger.error("[captureGitDiff] Error emitting pwd check", err);
        resolve({ success: false });
      }
    });

    serverLogger.info(
      `[AgentSpawner] Working directory check: ${pwdResult.stdout}`
    );

    // First check git status to understand the repo state
    const gitStatusVerbose = await new Promise<{
      success: boolean;
      stdout?: string;
      stderr?: string;
    }>((resolve) => {
      try {
        workerSocket.timeout(5000).emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "git status --verbose"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError) {
              if (timeoutError instanceof Error && timeoutError.message === "operation has timed out") {
                serverLogger.error("[captureGitDiff] Socket timeout on git status", timeoutError);
              }
              resolve({
                success: false,
                stderr: "timeout",
              });
              return;
            }
            if (result?.error) {
              resolve({
                success: false,
                stderr: String(result.error),
              });
              return;
            }
            resolve({
              success: true,
              stdout: result.data?.stdout || "",
              stderr: result.data?.stderr || "",
            });
          }
        );
      } catch (err) {
        serverLogger.error("[captureGitDiff] Error emitting git status", err);
        resolve({ success: false, stderr: "error" });
      }
    });

    serverLogger.info(
      `[AgentSpawner] Git status verbose: ${gitStatusVerbose.stdout?.substring(0, 500) || gitStatusVerbose.stderr}`
    );

    // First, let's see what files exist
    const lsResult = await new Promise<{
      success: boolean;
      stdout?: string;
    }>((resolve) => {
      workerSocket.timeout(5000).emit(
        "worker:exec",
        {
          command: "bash",
          args: ["-c", "ls -la"],
          cwd: containerWorkspace,
          env: {},
        },
        (timeoutError, result) => {
          if (timeoutError || result.error) {
            resolve({ success: false });
            return;
          }
          resolve({
            success: true,
            stdout: result.data?.stdout || "",
          });
        }
      );
    });

    serverLogger.info(
      `[AgentSpawner] Directory listing: ${lsResult.stdout?.split("\n").length || 0} files`
    );

    // Run git status to see all changes including untracked files
    const statusResult = await new Promise<{
      success: boolean;
      stdout?: string;
      stderr?: string;
    }>((resolve) => {
      workerSocket.timeout(10000).emit(
        "worker:exec",
        {
          command: "bash",
          args: ["-c", "git status --porcelain"],
          cwd: containerWorkspace,
          env: {},
        },
        (timeoutError, result) => {
          if (timeoutError || result.error) {
            resolve({ success: false });
            return;
          }
          resolve({
            success: true,
            stdout: result.data?.stdout || "",
            stderr: result.data?.stderr || "",
          });
        }
      );
    });

    let fullDiff = "";

    if (statusResult.success && statusResult.stdout) {
      fullDiff += `=== Git Status (porcelain) ===\n${statusResult.stdout}\n\n`;
      serverLogger.info(
        `[AgentSpawner] Git status shows ${statusResult.stdout.split("\n").filter((l) => l.trim()).length} changed files`
      );
    } else {
      serverLogger.warn(`[AgentSpawner] Git status failed or empty`);
    }

    // First get regular diff of tracked files
    const diffResult = await new Promise<{
      success: boolean;
      stdout?: string;
    }>((resolve) => {
      workerSocket.timeout(10000).emit(
        "worker:exec",
        {
          command: "bash",
          args: ["-c", "git diff"],
          cwd: containerWorkspace,
          env: {},
        },
        (timeoutError, result) => {
          if (timeoutError || result.error) {
            resolve({ success: false });
            return;
          }
          resolve({
            success: true,
            stdout: result.data?.stdout || "",
          });
        }
      );
    });

    if (diffResult.success && diffResult.stdout) {
      fullDiff += `=== Tracked file changes (git diff) ===\n${diffResult.stdout}\n\n`;
      serverLogger.info(
        `[AgentSpawner] Git diff length: ${diffResult.stdout.length} chars`
      );
    }

    // CRITICAL: Add files selectively, excluding unnecessary files
    serverLogger.info(
      `[AgentSpawner] Running selective git add to stage relevant code files`
    );
    
    // First, reset any previously staged files to start fresh
    await safeSocketExec(
      workerSocket,
      "git",
      ["reset"],
      containerWorkspace
    );
    
    // Define patterns to exclude from git diff
    const excludePatterns = [
      "*.lock",
      "*-lock.json",
      "*-lock.yaml",
      "pnpm-lock.yaml",
      "yarn.lock",
      "package-lock.json",
      "Gemfile.lock",
      "poetry.lock",
      "Pipfile.lock",
      "composer.lock",
      "*.log",
      "*.tmp",
      "*.cache",
      ".DS_Store",
      "node_modules/**",
      "dist/**",
      "build/**",
      ".next/**",
      "out/**",
      ".turbo/**",
      "coverage/**",
      ".nyc_output/**",
      "*.min.js",
      "*.min.css",
      "*.map",
      ".env.local",
      ".env.*.local"
    ];
    
    // Build git add command with pathspec magic to exclude files
    // Using :(exclude) pathspec magic
    const excludeArgs = excludePatterns.map(pattern => `':(exclude)${pattern}'`).join(' ');
    const addCommand = `git add -A . ${excludeArgs}`;
    
    serverLogger.info(
      `[AgentSpawner] Add command: ${addCommand}`
    );
    
    const addResult = await new Promise<{
      success: boolean;
      stdout?: string;
      stderr?: string;
    }>((resolve) => {
      workerSocket.timeout(10000).emit(
        "worker:exec",
        {
          command: "bash",
          args: [
            "-c",
            `cd /root/workspace && ${addCommand} && git status --short`,
          ],
          cwd: containerWorkspace,
          env: {},
        },
        (timeoutError, result) => {
          if (timeoutError || result.error) {
            resolve({
              success: false,
              stderr: String(result?.error || "timeout"),
            });
            return;
          }
          resolve({
            success: true,
            stdout: result.data?.stdout || "",
            stderr: result.data?.stderr || "",
          });
        }
      );
    });

    if (addResult.success) {
      serverLogger.info(
        `[AgentSpawner] Git add completed. Output: ${addResult.stdout || "no output"}, Stderr: ${addResult.stderr || "no stderr"}`
      );

      // Now get diff of staged changes with additional filtering
      serverLogger.info(
        `[AgentSpawner] Running git diff to get relevant code changes`
      );
      
      // Use git diff with pathspec to further filter if needed
      // Also add --stat to get a summary first
      const diffCommand = "git diff --cached --stat && echo '\n=== DETAILED DIFF ===' && git diff --cached";
      
      const stagedDiffResult = await new Promise<{
        success: boolean;
        stdout?: string;
        stderr?: string;
      }>((resolve) => {
        workerSocket
          .timeout(20000) // Increase timeout for large diffs
          .emit(
            "worker:exec",
            {
              command: "bash",
              args: ["-c", `cd /root/workspace && ${diffCommand} 2>&1`],
              cwd: containerWorkspace,
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError || result.error) {
                resolve({
                  success: false,
                  stderr: String(result?.error || "timeout"),
                });
                return;
              }
              resolve({
                success: true,
                stdout: result.data?.stdout || "",
                stderr: result.data?.stderr || "",
              });
            }
          );
      });

      if (stagedDiffResult.success) {
        serverLogger.info(
          `[AgentSpawner] Git diff HEAD completed. Length: ${stagedDiffResult.stdout?.length || 0}, Stderr: ${stagedDiffResult.stderr || "no stderr"}`
        );

        if (stagedDiffResult.stdout && stagedDiffResult.stdout.length > 0) {
          // Clean up the diff to remove any remaining unwanted file types
          const cleanedDiff = filterGitDiff(stagedDiffResult.stdout);
          fullDiff = `=== ALL CHANGES (git diff HEAD) ===\n${cleanedDiff}\n=== END ALL CHANGES ===`;
          serverLogger.info(
            `[AgentSpawner] Successfully captured diff: original ${stagedDiffResult.stdout.length} chars, cleaned ${cleanedDiff.length} chars`
          );
        } else {
          serverLogger.error(
            `[AgentSpawner] git diff HEAD returned empty! This should not happen after git add .`
          );

          // Debug: Check what git thinks is staged
          const debugStatusResult = await new Promise<{
            success: boolean;
            stdout?: string;
          }>((resolve) => {
            workerSocket.timeout(5000).emit(
              "worker:exec",
              {
                command: "bash",
                args: ["-c", "git status --short"],
                cwd: containerWorkspace,
                env: {},
              },
              (timeoutError, result) => {
                if (timeoutError || result.error) {
                  resolve({ success: false });
                  return;
                }
                resolve({
                  success: true,
                  stdout: result.data?.stdout || "",
                });
              }
            );
          });

          serverLogger.error(
            `[AgentSpawner] Git status after add: ${debugStatusResult.stdout}`
          );
          fullDiff = `ERROR: git diff --cached was empty. Git status:\n${debugStatusResult.stdout}`;
        }
      } else {
        serverLogger.error(
          `[AgentSpawner] Git diff --cached failed: ${stagedDiffResult.stderr}`
        );
      }

      // IMPORTANT: Keep files staged so crown evaluation can see them
      serverLogger.info(
        `[AgentSpawner] Keeping files staged for crown evaluation`
      );
    } else {
      serverLogger.error(
        `[AgentSpawner] Git add . failed: ${addResult.stderr}`
      );
    }

    // If still no diff, try to show what files are in the directory
    if (!fullDiff || fullDiff === "No changes detected") {
      const findResult = await new Promise<{
        success: boolean;
        stdout?: string;
      }>((resolve) => {
        workerSocket.timeout(5000).emit(
          "worker:exec",
          {
            command: "bash",
            args: [
              "-c",
              "find . -type f -name '*.md' -o -name '*.txt' -o -name '*.js' -o -name '*.ts' -o -name '*.json' | head -20",
            ],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false });
              return;
            }
            resolve({
              success: true,
              stdout: result.data?.stdout || "",
            });
          }
        );
      });

      if (findResult.success && findResult.stdout) {
        fullDiff = `No git changes detected. Files in directory:\n${findResult.stdout}`;
      }
    }

    // AGGRESSIVE FINAL CHECK - Get ALL changes by any means necessary
    if (!fullDiff || fullDiff.length < 50 || !fullDiff.includes("diff --git")) {
      serverLogger.warn(
        `[AgentSpawner] No meaningful diff found, using AGGRESSIVE capture`
      );

      // Method 1: Get list of all changed files from git status
      const changedFilesResult = await new Promise<{
        success: boolean;
        stdout?: string;
      }>((resolve) => {
        workerSocket.timeout(10000).emit(
          "worker:exec",
          {
            command: "bash",
            args: ["-c", "git status --porcelain | awk '{print $2}'"],
            cwd: containerWorkspace,
            env: {},
          },
          (timeoutError, result) => {
            if (timeoutError || result.error) {
              resolve({ success: false });
              return;
            }
            resolve({
              success: true,
              stdout: result.data?.stdout || "",
            });
          }
        );
      });

      if (changedFilesResult.success && changedFilesResult.stdout) {
        const files = changedFilesResult.stdout
          .split("\n")
          .filter((f) => f.trim());
        serverLogger.info(
          `[AgentSpawner] Found ${files.length} changed files to capture`
        );

        fullDiff = "=== AGGRESSIVE DIFF CAPTURE ===\n";

        // For each file, get its content
        for (const file of files) {
          if (!file) continue;

          // Check if file exists
          const fileExistsResult = await new Promise<{
            success: boolean;
            stdout?: string;
          }>((resolve) => {
            workerSocket.timeout(5000).emit(
              "worker:exec",
              {
                command: "bash",
                args: [
                  "-c",
                  `test -f "${file}" && echo "exists" || echo "not found"`,
                ],
                cwd: containerWorkspace,
                env: {},
              },
              (timeoutError, result) => {
                if (timeoutError || result.error) {
                  resolve({ success: false });
                  return;
                }
                resolve({
                  success: true,
                  stdout: result.data?.stdout || "",
                });
              }
            );
          });

          if (
            fileExistsResult.success &&
            fileExistsResult.stdout?.includes("exists")
          ) {
            // Get file content
            const fileContentResult = await new Promise<{
              success: boolean;
              stdout?: string;
            }>((resolve) => {
              workerSocket.timeout(5000).emit(
                "worker:exec",
                {
                  command: "bash",
                  args: ["-c", `cat "${file}" 2>/dev/null | head -1000`],
                  cwd: containerWorkspace,
                  env: {},
                },
                (timeoutError, result) => {
                  if (timeoutError || result.error) {
                    resolve({ success: false });
                    return;
                  }
                  resolve({
                    success: true,
                    stdout: result.data?.stdout || "",
                  });
                }
              );
            });

            if (fileContentResult.success && fileContentResult.stdout) {
              fullDiff += `\n=== NEW FILE: ${file} ===\n${fileContentResult.stdout}\n=== END FILE ===\n`;
            }
          }
        }
      }

      // Method 2: If still nothing, just list all files
      if (!fullDiff || fullDiff.length < 100) {
        const allFilesResult = await new Promise<{
          success: boolean;
          stdout?: string;
        }>((resolve) => {
          workerSocket.timeout(5000).emit(
            "worker:exec",
            {
              command: "bash",
              args: [
                "-c",
                "find . -type f -name '*.txt' -o -name '*.md' -o -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.py' -o -name '*.java' -o -name '*.c' -o -name '*.cpp' -o -name '*.go' -o -name '*.rs' | grep -v node_modules | grep -v .git | head -50",
              ],
              cwd: containerWorkspace,
              env: {},
            },
            (timeoutError, result) => {
              if (timeoutError || result.error) {
                resolve({ success: false });
                return;
              }
              resolve({
                success: true,
                stdout: result.data?.stdout || "",
              });
            }
          );
        });

        if (allFilesResult.success && allFilesResult.stdout) {
          fullDiff = `=== NO GIT DIFF FOUND - SHOWING ALL FILES ===\n${allFilesResult.stdout}\n`;
        }
      }
    }

    serverLogger.info(
      `[AgentSpawner] Total diff captured: ${fullDiff.length} chars`
    );
    serverLogger.info(
      `[AgentSpawner] First 200 chars: ${fullDiff.substring(0, 200)}`
    );
    return fullDiff || "No changes detected";
  } catch (error) {
    serverLogger.error(`[AgentSpawner] Error capturing git diff:`, error);
    return "";
  }
}
