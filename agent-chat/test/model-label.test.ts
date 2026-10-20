import { prettifyModelLabel, prettifyProviderModelLabel } from "../adapters/model-label";

const cases: Array<[string, string]> = [
  ["GPT-5.5", "GPT-5.5"],
  ["gpt-5.4", "GPT-5.4"],
  ["GPT-5.4-Mini", "GPT-5.4 Mini"],
  ["gpt-5.3-codex", "GPT-5.3 Codex"],
  ["gpt-5.2", "GPT-5.2"],
  ["glm-4.6-air", "GLM-4.6 Air"],
  ["Frontier model with long context", "Frontier model with long context"],
];

for (const [input, expected] of cases) {
  const actual = prettifyModelLabel(input);
  if (actual !== expected) throw new Error(`${input}: expected ${expected}, got ${actual}`);
}

const pi = prettifyProviderModelLabel("openai", "gpt-5.4-mini");
if (pi !== "openai/GPT-5.4 Mini") throw new Error(`pi provider/model label mismatch: ${pi}`);

console.log("model label prettifier: OK");
