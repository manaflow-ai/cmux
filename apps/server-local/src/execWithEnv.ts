import { exec } from "node:child_process";
import { promisify } from "node:util";

// Helper to execute commands with inherited environment
const execAsync = promisify(exec);

export const execWithEnv = (command: string) => {
  // Use zsh to ensure we get the user's shell environment and gh auth
  return execAsync(`/bin/zsh -c '${command}'`, {
    env: {
      ...process.env,
    },
  });
};
