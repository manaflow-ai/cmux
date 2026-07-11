import { claudeIndependentLaunchEnvironment } from "../adapters/claude";

const inherited = {
  PATH: "/usr/bin:/bin",
  CLAUDE_CODE_USE_VERTEX: "1",
  CLAUDECODE: "1",
  CLAUDE_CODE: "1",
  CLAUDE_CODE_CHILD_SESSION: "1",
  CLAUDE_CODE_BRIDGE_SESSION_ID: "bridge-session",
  CLAUDE_CODE_PARENT_SESSION_ID: "parent-session",
  CLAUDE_CODE_SESSION_ID: "session",
  CLAUDE_CODE_ENTRYPOINT: "cli",
  CLAUDE_CODE_EXECPATH: "/usr/bin/claude",
  CLAUDE_CODE_SSE_PORT: "12345",
  CLAUDE_CODE_SANDBOXED: "1",
  CMUX_CLAUDE_TEAMS_SANDBOXED: "1",
};

const launchEnvironment = claudeIndependentLaunchEnvironment(inherited);

for (const key of Object.keys(inherited).filter((key) => key !== "PATH" && key !== "CLAUDE_CODE_USE_VERTEX")) {
  if (key in launchEnvironment) throw new Error(`independent Claude launch inherited ${key}`);
}
if (launchEnvironment.PATH !== inherited.PATH) throw new Error("independent Claude launch dropped PATH");
if (launchEnvironment.CLAUDE_CODE_USE_VERTEX !== inherited.CLAUDE_CODE_USE_VERTEX) {
  throw new Error("independent Claude launch dropped backend selection");
}
if (!("CLAUDE_CODE_BRIDGE_SESSION_ID" in inherited)) {
  throw new Error("environment sanitizer mutated its input");
}

console.log("claude independent-launch environment assertions passed");

export {};
