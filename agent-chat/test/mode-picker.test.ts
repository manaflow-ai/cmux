import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { StatusRow } from "../src/components/StatusRow";
import type { SessionOption } from "../src/session";

Object.defineProperty(globalThis, "document", {
  configurable: true,
  value: { documentElement: {} },
});
Object.defineProperty(globalThis, "getComputedStyle", {
  configurable: true,
  value: () => ({ getPropertyValue: () => "" }),
});

const mutations: unknown[] = [];
function renderMode(option: SessionOption | undefined, running: boolean): string {
  return renderToStaticMarkup(React.createElement(StatusRow, {
    provider: "claude",
    cwd: "/work/project",
    options: option ? [option] : [],
    onChange: (id: string, value: unknown) => { mutations.push({ id, value }); },
    openOptionId: null,
    setOpenOptionId: () => {},
    running,
  }));
}

const choices = [
  { value: "default", label: "Default" },
  { value: "build", label: "Build" },
  { value: "plan", label: "Plan" },
  { value: "acceptEdits", label: "Accept edits" },
];

for (const running of [false, true]) {
  for (const id of ["mode", "permissionMode"]) {
    for (const choice of choices) {
      const option: SessionOption = { id, label: "Mode", kind: "select", value: choice.value, choices };
      const markup = renderMode(option, running);
      const trigger = markup.match(/<button\b[^>]*aria-label="Mode"[^>]*>[\s\S]*?<\/button>/)?.[0];
      assert.ok(trigger, `${id}=${choice.value}, running=${running}: the mode must have an accessible visible picker`);
      assert.ok(trigger.includes(choice.label), "the picker must display the selected provider label");
      assert.ok(trigger.includes('aria-haspopup="dialog"'), "opening the picker should offer a deliberate choice");
    }
    const disabled = renderMode({ id, label: "Mode", kind: "select", value: "plan", choices, disabled: true }, running);
    const trigger = disabled.match(/<button\b[^>]*aria-label="Mode"[^>]*>/)?.[0];
    assert.ok(trigger?.includes('disabled=""'), "a provider-disabled mode must not offer an active control");
  }
}
assert.ok(!renderMode(undefined, false).includes('aria-label="Mode"'), "providers without modes must not show a fake picker");
assert.deepEqual(mutations, [], "rendering a picker must preserve the provider's mode");
console.log("mode picker visibility and disabled-state assertions passed");
