import { claudeIndependentLaunchEnvironment } from "../adapters/claude";
import { inheritedClaudeLaunchStateKeys } from "../adapters/claude-environment-policy.generated";

const inherited: Record<string, string> = {
  PATH: "/usr/bin:/bin",
  CLAUDE_CODE_USE_VERTEX: "1",
};
for (const key of inheritedClaudeLaunchStateKeys) inherited[key] = "inherited-parent-value";

const launchEnvironment = claudeIndependentLaunchEnvironment(inherited);

for (const key of inheritedClaudeLaunchStateKeys) {
  if (key in launchEnvironment) throw new Error(`independent Claude launch inherited ${key}`);
}
if (launchEnvironment.PATH !== inherited.PATH) throw new Error("independent Claude launch dropped PATH");
if (launchEnvironment.CLAUDE_CODE_USE_VERTEX !== inherited.CLAUDE_CODE_USE_VERTEX) {
  throw new Error("independent Claude launch dropped backend selection");
}
for (const key of inheritedClaudeLaunchStateKeys) {
  if (!(key in inherited)) throw new Error(`environment sanitizer mutated its ${key} input`);
}

console.log("claude independent-launch environment assertions passed");

export {};
