import type { AgentSessionRateLimitRow } from "./types";

export type NormalizedRateLimitRow = AgentSessionRateLimitRow & {
  remainingPercent: number;
  usedPercent: number;
  windowDurationMins?: number;
};

export type RateLimitWindowLabels = {
  weekly: string;
  monthly: string;
};

export function normalizeRateLimitRow(row: AgentSessionRateLimitRow): NormalizedRateLimitRow {
  const usedPercent = Number.isFinite(row.usedPercent)
    ? clampPercent(row.usedPercent)
    : clampPercent(100 - row.remainingPercent);
  const remainingPercent = Number.isFinite(row.remainingPercent)
    ? clampPercent(row.remainingPercent)
    : clampPercent(100 - usedPercent);
  return {
    ...row,
    remainingPercent,
    usedPercent,
    windowDurationMins: Number.isFinite(row.windowDurationMins) ? row.windowDurationMins : undefined,
  };
}

export function activeRateLimitRow(rows: AgentSessionRateLimitRow[]): NormalizedRateLimitRow | null {
  const normalizedRows = rows.map(normalizeRateLimitRow);
  if (normalizedRows.length === 0) {
    return null;
  }
  return normalizedRows.reduce((current, candidate) => {
    if (candidate.usedPercent > current.usedPercent) {
      return candidate;
    }
    if (candidate.usedPercent < current.usedPercent) {
      return current;
    }
    return (candidate.windowDurationMins ?? -Infinity) > (current.windowDurationMins ?? -Infinity)
      ? candidate
      : current;
  });
}

export function formatRateLimitPercent(value: number): string {
  if (!Number.isFinite(value)) {
    return "100%";
  }
  return `${Math.round(clampPercent(value))}%`;
}

export function formatRateLimitReset(resetsAt: number | undefined, now = new Date()): string | null {
  if (resetsAt == null || !Number.isFinite(resetsAt)) {
    return null;
  }
  const date = new Date(resetsAt * 1000);
  if (!Number.isFinite(date.getTime())) {
    return null;
  }
  const secondsUntilReset = Math.floor((date.getTime() - now.getTime()) / 1000);
  if (secondsUntilReset > 0 && secondsUntilReset < 60 * 60) {
    return new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(date);
  }
  if (isSameLocalDay(date, now)) {
    return new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(date);
  }
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(date);
}

export function formatRateLimitWindow(
  minutes: number | undefined,
  fallback: string,
  labels?: RateLimitWindowLabels,
): string {
  if (minutes == null || !Number.isFinite(minutes) || minutes <= 0) {
    return fallback;
  }
  const rounded = Math.round(minutes);
  if (withinRatio(minutes, 30 * 24 * 60)) {
    return labels?.monthly ?? fallback;
  }
  if (withinRatio(minutes, 7 * 24 * 60)) {
    return labels?.weekly ?? fallback;
  }
  if (rounded >= 24 * 60) {
    return `${Math.ceil(rounded / (24 * 60))}d`;
  }
  if (rounded >= 60) {
    return `${Math.ceil(rounded / 60)}h`;
  }
  return `${Math.max(1, Math.ceil(rounded))}m`;
}

function clampPercent(value: number): number {
  if (!Number.isFinite(value)) {
    return 100;
  }
  return Math.min(Math.max(value, 0), 100);
}

function withinRatio(value: number, target: number): boolean {
  return value >= target * 0.95 && value <= target * 1.05;
}

function isSameLocalDay(date: Date, other: Date): boolean {
  return (
    date.getFullYear() === other.getFullYear() &&
    date.getMonth() === other.getMonth() &&
    date.getDate() === other.getDate()
  );
}
