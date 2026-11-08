import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { HarnessModelPicker, StatusRow, providerModelItemsForState } from "../src/components/StatusRow";
import { withLocalValues } from "../src/components/options";
import { loadingProviderOptionIds } from "../src/hooks/useCatalogs";
import type { Provider, SessionOption } from "../src/session";

Object.defineProperty(globalThis, "document", {
  configurable: true,
  value: { documentElement: {} },
});
Object.defineProperty(globalThis, "getComputedStyle", {
  configurable: true,
  value: () => ({ getPropertyValue: () => "" }),
});

const provider: Provider = { id: "codex", label: "Codex", installed: true };
const unavailableProvider: Provider = { id: "missing", label: "Missing", installed: false };

const pendingProviderIds = loadingProviderOptionIds([provider, unavailableProvider], {});
if (!pendingProviderIds.has(provider.id) || pendingProviderIds.has(unavailableProvider.id)) {
  throw new Error(`only installed providers without a response should be loading, got ${[...pendingProviderIds]}`);
}
const emptyResponseProviderIds = loadingProviderOptionIds([provider], { [provider.id]: [] });
if (emptyResponseProviderIds.has(provider.id)) {
  throw new Error("an empty model response should be treated as loaded");
}

function renderPicker(running: boolean, options: SessionOption[], loading: boolean): string {
  return renderToStaticMarkup(React.createElement(HarnessModelPicker, {
    provider: provider.id,
    providers: [provider],
    options,
    allProviderOptions: options.length ? { [provider.id]: options } : {},
    loadingProviderIds: loading ? new Set([provider.id]) : new Set<string>(),
    open: false,
    onOpenChange: () => {},
    onSelect: () => {},
    running,
  }));
}

for (const [surface, running] of [["task composer", false], ["running provider control", true]] as const) {
  const markup = renderPicker(running, [], true);
  if (!markup.includes('role="status"') || !markup.includes('aria-label="Loading models"')) {
    throw new Error(`${surface}: expected an accessible model-loading indicator, got ${markup}`);
  }
  if (!markup.includes("pinwheel-spinner")) {
    throw new Error(`${surface}: expected the model-loading spinner, got ${markup}`);
  }
}

const fallbackOptions: SessionOption[] = [{
  id: "model",
  label: "Model",
  kind: "select",
  value: "fallback-model",
  choices: [{ value: "fallback-model", label: "Fallback model" }],
}];
const pendingItems = providerModelItemsForState(provider, provider.id, fallbackOptions, true);
if (pendingItems.length) {
  throw new Error(`pending picker should not bury its loading state under fallback model rows, got ${JSON.stringify(pendingItems)}`);
}

const modelSpecificOptions = [{
  id: "model",
  label: "Model",
  kind: "select",
  value: "fast-model",
  choices: [
    {
      value: "fast-model",
      label: "Fast model",
      efforts: [{ value: "low", label: "Low" }],
      defaultEffort: "low",
    },
    {
      value: "deep-model",
      label: "Deep model",
      efforts: [{ value: "high", label: "High" }, { value: "xhigh", label: "Extra high" }],
      defaultEffort: "high",
    },
    { value: "no-effort-model", label: "No effort model" },
  ],
}, {
  id: "effort",
  label: "Effort",
  kind: "select",
  role: "effort",
  value: "low",
  choices: [{ value: "low", label: "Low" }],
}] as SessionOption[];

const deepModelOptions = withLocalValues(modelSpecificOptions, { model: "deep-model", effort: "low" });
const deepEffort = deepModelOptions.find((option) => option.role === "effort");
if (deepEffort?.value !== "high" || deepEffort.choices?.map((choice) => choice.value).join(",") !== "high,xhigh") {
  throw new Error(`effort picker should use the selected model's reported choices and default, got ${JSON.stringify(deepEffort)}`);
}
const noEffortOptions = withLocalValues(modelSpecificOptions, { model: "no-effort-model" });
if (noEffortOptions.some((option) => option.role === "effort")) {
  throw new Error(`model without reported effort metadata should not inherit provider-wide choices, got ${JSON.stringify(noEffortOptions)}`);
}

const orderedStatusMarkup = renderToStaticMarkup(React.createElement(StatusRow, {
  provider: provider.id,
  providers: [provider],
  allProviderOptions: { [provider.id]: modelSpecificOptions },
  loadingProviderIds: new Set<string>(),
  onProviderModelChange: () => {},
  cwd: "/tmp",
  options: [
    ...modelSpecificOptions,
    { id: "fastMode", label: "Fast", kind: "toggle", value: false },
  ],
  onChange: () => {},
  openOptionId: null,
  setOpenOptionId: () => {},
}));
const effortIndex = orderedStatusMarkup.indexOf('aria-label="Effort"');
const fastIndex = orderedStatusMarkup.indexOf('aria-label="Fast"');
if (effortIndex < 0 || fastIndex < 0 || effortIndex > fastIndex) {
  throw new Error(`effort picker should appear immediately after the model picker and before fast mode, got ${orderedStatusMarkup}`);
}

const loadingStatusMarkup = renderToStaticMarkup(React.createElement(StatusRow, {
  provider: provider.id,
  providers: [provider],
  allProviderOptions: { [provider.id]: modelSpecificOptions },
  loadingProviderIds: new Set([provider.id]),
  onProviderModelChange: () => {},
  cwd: "/tmp",
  options: modelSpecificOptions,
  onChange: () => {},
  openOptionId: null,
  setOpenOptionId: () => {},
}));
if (!loadingStatusMarkup.includes('aria-label="Loading effort"') || loadingStatusMarkup.includes('aria-label="Effort"')) {
  throw new Error(`loading provider should show the effort loading state without a stale effort picker, got ${loadingStatusMarkup}`);
}

const loadedOptions: SessionOption[] = [{
  id: "model",
  label: "Model",
  kind: "select",
  value: "gpt-5.6-sol",
  choices: [{ value: "gpt-5.6-sol", label: "GPT-5.6 Sol" }],
}];
const loadedMarkup = renderPicker(false, loadedOptions, false);
if (loadedMarkup.includes('aria-label="Loading models"') || !loadedMarkup.includes('data-visible="false"')) {
  throw new Error(`loaded picker should keep its animated loading indicator hidden and inaccessible, got ${loadedMarkup}`);
}
if (!loadedMarkup.includes("GPT-5.6 Sol")) {
  throw new Error(`loaded picker should show the selected model, got ${loadedMarkup}`);
}

console.log("model picker loading indicator: OK");
