import fs from "node:fs";
import { DockerVSCodeInstance } from "../vscode/DockerVSCodeInstance.js";

async function main() {
  const prompt = process.argv[2];
  if (!prompt) {
    console.error("Usage: spawn-vscode-with-class.ts <prompt>");
    process.exit(1);
  }

  console.log(`Spawning VSCode with prompt: ${prompt}`);

  // Create VSCode instance using the abstraction
  const vscodeInstance = new DockerVSCodeInstance({
    agentName: "claude-demo",
    taskRunId: "test-task-run-id", // Add required taskRunId for testing
  });

  try {
    // Start the VSCode instance
    const info = await vscodeInstance.start();

    console.log(`\nVSCode instance started:`);
    console.log(`  URL: ${info.workspaceUrl}`);
    console.log(`  Instance ID: ${info.instanceId}`);

    // Get the worker socket from the instance
    const workerSocket = vscodeInstance.getWorkerSocket();

    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      throw new Error("Worker socket not available");
    }

    // Create terminal with Claude Code
    const terminalId = "claude-terminal";
    const command = "bash";
    const escapedPrompt = prompt
      .replace(/\\/g, "\\\\") 
      .replace(/"/g, '\\"')    
      .replace(/\$/g, "\\$")   
      .replace(/`/g, "\\`");  
    const args = [
      "-c",
      `bunx @anthropic-ai/claude-code --model claude-sonnet-4-20250514 --dangerously-skip-permissions "${escapedPrompt}"`,
      // "@anthropic-ai/claude-code",
      // "--model",
      // "claude-sonnet-4-20250514",
      // "--dangerously-skip-permissions",
      // prompt,
    ];

    console.log(
      `\nCreating terminal with command: ${command} ${args.join(" ")}`
    );

    const claudeJsonRaw = fs.readFileSync(
      process.env.HOME + "/.claude.json",
      "utf-8"
    );
    const claudeJson = JSON.parse(claudeJsonRaw);
    claudeJson["projects"] = {};
    claudeJson["projects"]["/root/workspace"] = {
      allowedTools: [],
      history: [],
      mcpContextUris: [],
      mcpServers: {},
      enabledMcpjsonServers: [],
      disabledMcpjsonServers: [],
      hasTrustDialogAccepted: true,
      projectOnboardingSeenCount: 0,
      hasClaudeMdExternalIncludesApproved: false,
      hasClaudeMdExternalIncludesWarningShown: false,
    };
    const claudeJsonBase64 = Buffer.from(JSON.stringify(claudeJson)).toString(
      "base64"
    );

    // Send terminal creation request
    await new Promise((resolve, reject) => {
      workerSocket.emit(
        "worker:create-terminal",
        {
          terminalId,
          command,
          args,
          cols: 80,
          rows: 24,
          env: {},
          authFiles: [
            {
              contentBase64: claudeJsonBase64,
              destinationPath: "/root/.claude.json",
            },
          ],
        },
        (result) => {
          if (result.error) {
            reject(result.error);
          } else {
            console.log("Terminal created successfully", result);
            resolve(result.data);
          }
        }
      );
    });

    console.log(`\n✅ VSCode is running at: ${info.workspaceUrl}`);
    console.log(
      "\nClaude Code is running in the terminal. Open the URL above to interact with it."
    );
    console.log("Press Ctrl+C to stop\n");

    // Handle graceful shutdown
    process.on("SIGINT", async () => {
      console.log("\nStopping VSCode instance...");
      await vscodeInstance.stop();
      process.exit(0);
    });

    // Keep the process running
    await new Promise(() => {});
  } catch (error) {
    console.error("Error:", error);
    await vscodeInstance.stop();
    process.exit(1);
  }
}

main().catch(console.error);
