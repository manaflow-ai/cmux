import { AGENT_CONFIGS } from "@cmux/shared/agentConfig";
import z from "zod";

const DEFAULT_AGENT_CANDIDATES = [
  "claude/sonnet-4.5",
  "claude/opus-4.1",
  "codex/gpt-5-codex-high",
];

const AGENT_SELECTION_STORAGE_KEY = "selectedAgents";

const AGENT_SELECTION_SCHEMA = z.array(z.string());

export const KNOWN_AGENT_NAMES = new Set(
  AGENT_CONFIGS.map((agent) => agent.name),
);

export const DEFAULT_AGENT_SELECTION = DEFAULT_AGENT_CANDIDATES.filter((agent) =>
  KNOWN_AGENT_NAMES.has(agent),
);

export function filterKnownAgents(agents: string[]): string[] {
  return agents.filter((agent) => KNOWN_AGENT_NAMES.has(agent));
}

function safeGetItem(key: string): string | null {
  if (typeof window === "undefined") {
    return null;
  }
  try {
    return window.localStorage.getItem(key);
  } catch (error) {
    console.warn("Failed to read localStorage", error);
    return null;
  }
}

function safeSetItem(key: string, value: string | null): void {
  if (typeof window === "undefined") {
    return;
  }
  try {
    if (value === null) {
      window.localStorage.removeItem(key);
    } else {
      window.localStorage.setItem(key, value);
    }
  } catch (error) {
    console.warn("Failed to write localStorage", error);
  }
}

export function parseStoredAgentSelection(stored: string | null): string[] {
  if (!stored) {
    return [];
  }

  try {
    const parsed = JSON.parse(stored);
    const result = AGENT_SELECTION_SCHEMA.safeParse(parsed);
    if (!result.success) {
      console.warn("Invalid stored agent selection", result.error);
      return [];
    }
    return filterKnownAgents(result.data);
  } catch (error) {
    console.warn("Failed to parse stored agent selection", error);
    return [];
  }
}

export function loadPersistedAgentSelection(): string[] {
  const stored = safeGetItem(AGENT_SELECTION_STORAGE_KEY);
  const parsed = parseStoredAgentSelection(stored);
  if (parsed.length > 0) {
    return parsed;
  }
  return DEFAULT_AGENT_SELECTION.length > 0
    ? [...DEFAULT_AGENT_SELECTION]
    : [];
}

export function persistAgentSelection(agents: string[]): void {
  const filtered = filterKnownAgents(agents);
  const isDefaultSelection =
    DEFAULT_AGENT_SELECTION.length > 0 &&
    filtered.length === DEFAULT_AGENT_SELECTION.length &&
    filtered.every((agent, index) => agent === DEFAULT_AGENT_SELECTION[index]);

  if (filtered.length === 0 || isDefaultSelection) {
    safeSetItem(AGENT_SELECTION_STORAGE_KEY, null);
    return;
  }

  safeSetItem(AGENT_SELECTION_STORAGE_KEY, JSON.stringify(filtered));
}
