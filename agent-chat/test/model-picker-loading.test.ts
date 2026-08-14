import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { HarnessModelPicker, providerModelItemsForState } from "../src/components/StatusRow";
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

const loadedOptions: SessionOption[] = [{
  id: "model",
  label: "Model",
  kind: "select",
  value: "gpt-5.6-sol",
  choices: [{ value: "gpt-5.6-sol", label: "GPT-5.6 Sol" }],
}];
const loadedMarkup = renderPicker(false, loadedOptions, false);
if (loadedMarkup.includes('aria-label="Loading models"') || loadedMarkup.includes("pinwheel-spinner")) {
  throw new Error(`loaded picker should remove its loading indicator, got ${loadedMarkup}`);
}
if (!loadedMarkup.includes("GPT-5.6 Sol")) {
  throw new Error(`loaded picker should show the selected model, got ${loadedMarkup}`);
}

console.log("model picker loading indicator: OK");
