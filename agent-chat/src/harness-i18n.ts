import type { HarnessCatalogs, HarnessMessage, HarnessMessages } from "../harness-contract";

export function selectHarnessLocale(catalogs: HarnessCatalogs, languages: readonly string[]): string {
  for (const language of languages) {
    const canonical = language.toLowerCase();
    const exact = Object.keys(catalogs).find((key) => key.toLowerCase() === canonical);
    if (exact) return exact;
    const base = canonical.split("-")[0];
    const alias = base === "zh" ? (/hant|tw|hk|mo/.test(canonical) ? "zh-TW" : "zh-CN") : base === "pt" ? "pt-BR" : base === "nb" || base === "nn" ? "no" : base;
    if (catalogs[alias]) return alias;
  }
  return "en";
}

export function formatHarnessMessage(messages: HarnessMessages, key: keyof HarnessMessages, params: Record<string, string> = {}): string {
  return (messages[key] ?? "").replace(/\{(\w+)\}/g, (placeholder, name) => params[name] ?? placeholder);
}

export function renderHarnessMessage(messages: HarnessMessages, message?: HarnessMessage): string {
  return message ? formatHarnessMessage(messages, message.id, message.params) : "";
}
