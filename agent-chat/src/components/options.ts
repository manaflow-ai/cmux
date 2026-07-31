import type { OptionValue, SessionOption } from "../session";
import type { KeyAction } from "../keymap";

export function currentChoice(option?: SessionOption) {
  if (!option) return null;
  const value = String(option.value ?? "");
  return option.choices?.find((c) => c.value === value) ?? (value ? { value, label: value } : null);
}

export function isOffLikeValue(value: string): boolean {
  return /^(off|none|no[-_ ]?reasoning)$/i.test(value);
}

export function visibleChoices(option: SessionOption) {
  const choices = option.choices ?? [];
  return option.role === "effort" ? choices.filter((c) => !isOffLikeValue(c.value)) : choices;
}

export function effortFill(option: SessionOption, value: OptionValue = option.value, bars = 4): number {
  const choices = visibleChoices(option);
  const count = choices.length || 1;
  const index = Math.max(0, choices.findIndex((c) => c.value === value));
  return Math.max(1, Math.round(((index + 1) / count) * bars));
}

export function prettyValue(option?: SessionOption): string {
  const choice = currentChoice(option);
  if (!choice) return "";
  const raw = String(choice.value ?? "");
  const label = String(choice.label ?? raw);
  if (label && label !== raw) return label;
  if (/^x/i.test(raw)) return "Extra high";
  if (raw === "max") return "Max";
  return raw
    .replace(/[-_]+/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

export function optionAction(id: string): KeyAction | undefined {
  if (id === "model") return "open-model";
  if (id === "effort" || id === "thinking") return "cycle-thinking";
  if (id === "fastMode") return "toggle-fast";
  if (id === "mode" || id === "permissionMode") return "cycle-mode";
  return undefined;
}

export function optionTooltip(option: SessionOption): string {
  if (option.id === "model") return "Adjust model";
  if (option.id === "context") return "Adjust context window";
  if (option.id === "effort") return "Adjust effort level";
  if (option.id === "thinking") return "Adjust thinking level";
  if (option.id === "fastMode") return "Toggle fast mode";
  if (option.id === "mode" || option.id === "permissionMode") return "Change mode";
  return `Adjust ${option.label}`;
}

export function optionAcceptsValue(option: SessionOption, value: OptionValue): boolean {
  if (option.kind === "toggle") return typeof value === "boolean";
  if (typeof value !== "string") return false;
  return Boolean(option.choices?.some((c) => c.value === value && !c.disabled));
}

export function sanitizeStartOptions(dirty: Record<string, OptionValue>, options: SessionOption[]): Record<string, OptionValue> {
  const byId = new Map(options.map((o) => [o.id, o]));
  const out: Record<string, OptionValue> = {};
  for (const [id, value] of Object.entries(dirty)) {
    const option = byId.get(id);
    if (option && optionAcceptsValue(option, value)) out[id] = value;
  }
  return out;
}

export function withLocalValues(options: SessionOption[], local: Record<string, OptionValue>): SessionOption[] {
  return options.map((o) => {
    if (!Object.prototype.hasOwnProperty.call(local, o.id)) return o;
    const value = local[o.id];
    return optionAcceptsValue(o, value) ? { ...o, value } : o;
  });
}

export function cycleSelect(option: SessionOption, onChange: (id: string, value: OptionValue) => void) {
  const choices = visibleChoices(option);
  if (option.kind !== "select" || !choices.length || option.disabled) return;
  const i = choices.findIndex((c) => c.value === option.value);
  const next = choices[(i + 1 + choices.length) % choices.length];
  if (next) onChange(option.id, next.value);
}
