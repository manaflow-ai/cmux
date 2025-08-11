#!/usr/bin/env tsx
import Docker from "dockerode";

async function testDocker() {
  console.log("Testing Docker connection...");
  
  const configs = [
    { name: "Default", options: {} },
    { name: "Unix socket", options: { socketPath: '/var/run/docker.sock' } },
    { name: "OrbStack socket", options: { socketPath: `${process.env.HOME}/.orbstack/run/docker.sock` } },
    { name: "Host", options: { host: 'localhost', port: 39375 } }
  ];

  for (const config of configs) {
    console.log(`\nTrying ${config.name}...`);
    try {
      const docker = new Docker(config.options as Docker.DockerOptions);
      const info = await docker.info();
      console.log(`✅ Success! Docker version: ${info.ServerVersion}`);
      console.log(`   Using config:`, config.options);
      return;
    } catch (error: any) {
      console.log(`❌ Failed: ${error.message}`);
    }
  }
  
  console.log("\n❌ All connection methods failed!");
}

testDocker().catch(console.error);