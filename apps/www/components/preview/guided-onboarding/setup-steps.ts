import type { SetupStepConfig } from "./setup-step";

export const SETUP_STEPS: SetupStepConfig[] = [
  {
    id: "git-pull",
    title: "Sync repository",
    description:
      "Pull the latest code so the sandbox matches your main branch. This runs every time the environment starts.",
    defaultValue: "cd ~/repos/{repo} && git pull && git submodule update --init --recursive",
    placeholder: "git pull && git submodule update --init --recursive",
  },
  {
    id: "install-deps",
    title: "Install dependencies",
    description: "Install project dependencies once the repo is ready.",
    defaultValue: "npm install",
    placeholder: "npm install",
  },
  {
    id: "dev-server",
    title: "Start dev server",
    description: "Start the server you want preview.new to capture.",
    optional: true,
    defaultValue: "npm run dev",
    placeholder: "npm run dev",
  },
  {
    id: "browser-setup",
    title: "Browser setup",
    description:
      "Share any login flows or navigation steps the browser agent should follow to reach the target page.",
    optional: true,
    placeholder: "Open http://localhost:3000, sign in with demo@cmux.dev / demo123, then go to /dashboard.",
  },
  {
    id: "additional-notes",
    title: "Additional notes",
    description:
      "Anything else the preview or screenshot agents should know before they run.",
    optional: true,
    placeholder: "Use seeded data. The charts update after 5 seconds.",
  },
];
