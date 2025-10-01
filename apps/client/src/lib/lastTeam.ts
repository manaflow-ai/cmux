import { storage } from "@/lib/storage";

const LAST_TEAM_STORAGE_KEY = "cmux:lastTeamSlugOrId" as const;

export function getLastTeamSlugOrId(): string | null {
  const value = storage.getItem(LAST_TEAM_STORAGE_KEY);
  return value && value.trim().length > 0 ? value : null;
}

export function setLastTeamSlugOrId(value: string): void {
  storage.setItem(LAST_TEAM_STORAGE_KEY, value);
}

export function clearLastTeamSlugOrId(): void {
  storage.removeItem(LAST_TEAM_STORAGE_KEY);
}

export const LAST_TEAM_KEY = LAST_TEAM_STORAGE_KEY;
