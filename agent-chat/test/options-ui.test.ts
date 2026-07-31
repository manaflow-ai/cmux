import { prettyValue } from "../src/components/options";
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
