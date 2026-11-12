import { cycleSelect, prettyValue } from "../src/components/options";
import { actionSupported } from "../src/hooks/useKeymap";
import type { SessionOption } from "../src/session";

const effort: SessionOption = {
  id: "effort",
  label: "Effort",
  kind: "select",
  role: "effort",
  value: "low",
  choices: ["low", "medium", "high", "xhigh", "max"].map((value) => ({ value, label: value })),
};

const labels = effort.choices!.map((choice) => prettyValue({ ...effort, value: choice.value }));
if (new Set(labels).size !== labels.length) {
  throw new Error(`expected unique prettified effort labels, got ${labels.join(", ")}`);
}
if (!labels.includes("Extra high") || !labels.includes("Max")) {
  throw new Error(`expected xhigh and max labels, got ${labels.join(", ")}`);
}

console.log("options UI labels: OK");

const mode: SessionOption = {
  id: "permissionMode", label: "Mode", kind: "select", value: "plan",
  choices: [
    { value: "default", label: "Default" },
    { value: "plan", label: "Plan" },
    { value: "bypassPermissions", label: "Bypass permissions", disabled: true },
  ],
};
const changes: string[] = [];
cycleSelect(mode, (_id, value) => changes.push(String(value)));
if (changes.join() !== "default") {
  throw new Error(`cycling mode must skip disabled choices, got ${JSON.stringify(changes)}`);
}
cycleSelect({ ...mode, disabled: true }, (_id, value) => changes.push(String(value)));
if (changes.length !== 1) throw new Error("a disabled mode must not change");
cycleSelect({ ...mode, choices: mode.choices!.map((choice) => ({ ...choice, disabled: true })) },
  (_id, value) => changes.push(String(value)));
if (changes.length !== 1) throw new Error("a mode with no enabled choices must not change");

const blockedPlan = { ...mode, value: "default", choices: mode.choices!.map((choice) => ({ ...choice, disabled: choice.value !== "default" })) };
if (actionSupported("toggle-plan", [blockedPlan], false)) {
  throw new Error("the plan shortcut must not offer a provider-disabled plan");
}
if (!actionSupported("toggle-plan", [{ ...blockedPlan, value: "plan" }], false)) {
  throw new Error("the plan shortcut must allow returning from a disabled plan to an enabled default");
}
console.log("mode keyboard restrictions: OK");
