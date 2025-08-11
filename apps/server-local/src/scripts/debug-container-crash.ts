#!/usr/bin/env tsx
import Docker from "dockerode";

async function main() {
  const docker = new Docker({ socketPath: "/var/run/docker.sock" });
  const containerName = `cmux-vscode-debug-${Date.now()}`;

  console.log(`Creating container ${containerName}...`);

  const container = await docker.createContainer({
    name: containerName,
    Image: "cmux-worker:0.0.1",
    Env: ["NODE_ENV=production", "WORKER_PORT=39377"],
    HostConfig: {
      AutoRemove: false, // Don't auto-remove so we can inspect logs
      Privileged: true,
      PortBindings: {
        "39378/tcp": [{ HostPort: "0" }],
        "39377/tcp": [{ HostPort: "0" }],
      },
    },
    ExposedPorts: {
      "39378/tcp": {},
      "39377/tcp": {},
    },
  });

  console.log(`Starting container...`);
  await container.start();

  console.log(`Container started. Waiting 10 seconds...`);
  await new Promise((resolve) => setTimeout(resolve, 10000));

  console.log(`Getting container logs...`);
  const logs = await container.logs({
    stdout: true,
    stderr: true,
    timestamps: true,
    tail: 100,
  });

  console.log(`\n=== Container logs ===`);
  console.log(logs.toString());

  console.log(`\nChecking container status...`);
  const info = await container.inspect();
  console.log(`Running: ${info.State.Running}`);
  console.log(`Status: ${info.State.Status}`);
  console.log(`Exit code: ${info.State.ExitCode}`);

  if (!info.State.Running) {
    console.log(`\nContainer exited. Full state:`);
    console.log(JSON.stringify(info.State, null, 2));
  }

  console.log(`\nStopping and removing container...`);
  try {
    await container.stop();
  } catch (e) {
    // Ignore if already stopped
  }
  await container.remove();
}

main().catch(console.error);
