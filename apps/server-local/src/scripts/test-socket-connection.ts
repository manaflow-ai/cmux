#!/usr/bin/env tsx
import { DockerVSCodeInstance } from "../vscode/DockerVSCodeInstance.js";

async function main() {
  console.log("=== Testing Socket Connection ===\n");

  // Create VSCode instance
  const vscodeInstance = new DockerVSCodeInstance({
    agentName: "test-socket",
    taskRunId: "test-task-run-id", // Add required taskRunId for testing
  });

  try {
    // Start the VSCode instance
    const info = await vscodeInstance.start();
    console.log(`VSCode instance started:`);
    console.log(`  URL: ${info.workspaceUrl}`);
    console.log(`  Instance ID: ${info.instanceId}`);

    // Get the worker socket
    const workerSocket = vscodeInstance.getWorkerSocket();
    
    console.log(`\nSocket status:`);
    console.log(`  Socket exists: ${!!workerSocket}`);
    console.log(`  Worker connected: ${vscodeInstance.isWorkerConnected()}`);
    console.log(`  Socket connected: ${workerSocket?.connected}`);
    console.log(`  Socket ID: ${workerSocket?.id}`);

    if (!workerSocket || !vscodeInstance.isWorkerConnected()) {
      throw new Error("Worker socket not available");
    }

    // Try a simple ping first
    console.log(`\nTesting simple emit without callback...`);
    workerSocket.emit("worker:check-docker", () => {});
    console.log(`Emitted worker:check-docker`);

    // Wait a bit
    await new Promise(resolve => setTimeout(resolve, 1000));

    // Now try with callback
    console.log(`\nTesting emit with callback...`);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("Timeout waiting for docker check"));
      }, 5000);

      workerSocket.emit("worker:check-docker", (result) => {
        clearTimeout(timeout);
        console.log(`Got docker check result:`, result);
        resolve(result);
      });
    });

    // Now test terminal creation
    console.log(`\nTesting terminal creation...`);
    const terminalCommand = {
      terminalId: "test-terminal",
      command: "echo",
      args: ["Hello World"],
      cols: 80,
      rows: 24,
      env: {},
    };

    console.log(`Terminal command:`, terminalCommand);

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("Timeout waiting for terminal creation"));
      }, 10000);

      console.log(`About to emit worker:create-terminal...`);
      workerSocket.emit(
        "worker:create-terminal",
        terminalCommand,
        (result) => {
          clearTimeout(timeout);
          console.log(`Got terminal creation result:`, result);
          resolve(result);
        }
      );
      console.log(`Emitted worker:create-terminal`);
    });

    console.log(`\n✅ All tests passed!`);

  } catch (error) {
    console.error(`\n❌ Test failed:`, error);
  } finally {
    // Always cleanup
    console.log(`\nStopping VSCode instance...`);
    await vscodeInstance.stop();
  }
}

main().catch(console.error);