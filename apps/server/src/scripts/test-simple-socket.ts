#!/usr/bin/env tsx
import { connectToWorkerManagement } from "@cmux/shared/socket";
import type { DockerReadinessResponse } from "@cmux/shared";

async function main() {
  const workerUrl = process.argv[2];
  if (!workerUrl) {
    console.error("Usage: test-simple-socket.ts <worker-url>");
    process.exit(1);
  }

  console.log(`Connecting to ${workerUrl}/management...`);
  
  const socket = connectToWorkerManagement({ url: workerUrl, timeoutMs: 10_000, reconnectionAttempts: 0 });

  socket.on("connect", () => {
    console.log("Connected! Socket ID:", socket.id);

    // Try check-docker
    console.log("\nEmitting worker:check-docker...");
    socket.emit(
      "worker:check-docker",
      (result: DockerReadinessResponse) => {
        console.log("Got response:", result);

        // Now disconnect
        console.log("\nDisconnecting...");
        socket.disconnect();
        process.exit(0);
      }
    );
  });

  socket.on("connect_error", (error) => {
    console.error("Connection error:", error.message);
    process.exit(1);
  });

  socket.on("disconnect", (reason) => {
    console.log("Disconnected:", reason);
  });

  // Timeout after 10 seconds
  setTimeout(() => {
    console.error("Timeout!");
    process.exit(1);
  }, 10000);
}

main().catch(console.error);
