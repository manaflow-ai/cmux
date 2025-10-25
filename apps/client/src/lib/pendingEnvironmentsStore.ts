import { DEFAULT_MORPH_SNAPSHOT_ID, type MorphSnapshotId } from "@cmux/shared";
import { useSyncExternalStore } from "react";
import type { EnvVar } from "@/components/EnvironmentConfiguration";

export type PendingEnvironmentStep = "select" | "configure";
export type PendingEnvironmentId = string;

export interface PendingEnvironmentDraft {
  step?: PendingEnvironmentStep;
  selectedRepos?: string[];
  snapshotId?: MorphSnapshotId;
  connectionLogin?: string | null | undefined;
  repoSearch?: string | null;
  instanceId?: string;
  envName?: string | null;
  maintenanceScript?: string | null;
  devScript?: string | null;
  envVars?: EnvVar[] | null;
  exposedPorts?: string | null;
}

export interface PendingEnvironment extends PendingEnvironmentDraft {
  id: PendingEnvironmentId;
  teamSlugOrId: string;
  step: PendingEnvironmentStep;
  selectedRepos: string[];
  snapshotId: MorphSnapshotId;
  updatedAt: number;
  connectionLogin: string | null;
  repoSearch: string | null;
  envName: string;
  maintenanceScript: string;
  devScript: string;
  envVars: EnvVar[];
  exposedPorts: string;
}

const STORAGE_KEY = "cmux:pending-environments";

type TeamPendingEnvironmentMap = Record<PendingEnvironmentId, PendingEnvironment>;
type PendingEnvironmentState = Record<string, TeamPendingEnvironmentMap>;

type Listener = () => void;

const listeners = new Set<Listener>();

let state: PendingEnvironmentState = readFromStorage();
const pendingListCache = new Map<string, PendingEnvironment[]>();
const emptyPendingList: PendingEnvironment[] = [];

function createPendingEnvironmentId(): PendingEnvironmentId {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `pending-${Math.random().toString(36).slice(2, 10)}`;
}

function sanitizeEnvVars(input?: EnvVar[] | null): EnvVar[] {
  if (!Array.isArray(input)) {
    return [];
  }
  return input
    .filter((item) =>
      item && typeof item === "object" && typeof item.name === "string"
    )
    .map((item) => ({
      name: item.name,
      value: typeof item.value === "string" ? item.value : "",
      isSecret: item.isSecret !== false,
    }));
}

function sanitizePendingEnvironment(
  teamSlugOrId: string,
  id: PendingEnvironmentId,
  input: Partial<PendingEnvironment>
): PendingEnvironment {
  const step: PendingEnvironmentStep =
    input.step === "configure" ? "configure" : "select";
  const selectedRepos = Array.isArray(input.selectedRepos)
    ? Array.from(
        new Set(
          input.selectedRepos.filter((item): item is string =>
            typeof item === "string"
          )
        )
      )
    : [];
  const snapshotId =
    typeof input.snapshotId === "string"
      ? (input.snapshotId as MorphSnapshotId)
      : DEFAULT_MORPH_SNAPSHOT_ID;
  return {
    id,
    teamSlugOrId,
    step,
    selectedRepos,
    snapshotId,
    connectionLogin:
      input.connectionLogin === undefined ? null : input.connectionLogin,
    repoSearch: input.repoSearch === undefined ? null : input.repoSearch,
    instanceId:
      typeof input.instanceId === "string" && input.instanceId.length > 0
        ? input.instanceId
        : undefined,
    envName:
      input.envName === undefined || input.envName === null ? "" : input.envName,
    maintenanceScript:
      input.maintenanceScript === undefined || input.maintenanceScript === null
        ? ""
        : input.maintenanceScript,
    devScript:
      input.devScript === undefined || input.devScript === null
        ? ""
        : input.devScript,
    envVars: sanitizeEnvVars(input.envVars),
    exposedPorts:
      input.exposedPorts === undefined || input.exposedPorts === null
        ? ""
        : input.exposedPorts,
    updatedAt:
      typeof input.updatedAt === "number" ? input.updatedAt : Date.now(),
  };
}

function readFromStorage(): PendingEnvironmentState {
  if (typeof window === "undefined") {
    return {};
  }
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return {};
    }
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") {
      return {};
    }
    const input = parsed as Record<string, unknown>;
    const teamEntries: Array<[string, TeamPendingEnvironmentMap]> = [];
    for (const [teamKey, value] of Object.entries(input)) {
      if (!value || typeof value !== "object") {
        continue;
      }

      const teamMap: TeamPendingEnvironmentMap = {};

      if (Array.isArray(value)) {
        for (const item of value) {
          if (!item || typeof item !== "object") {
            continue;
          }
          const id = createPendingEnvironmentId();
          const sanitized = sanitizePendingEnvironment(teamKey, id, item as PendingEnvironment);
          teamMap[id] = sanitized;
        }
      } else {
        const recordValue = value as Record<string, unknown>;

        if (
          "step" in recordValue &&
          !("id" in recordValue) &&
          typeof recordValue.step === "string"
        ) {
          const id = createPendingEnvironmentId();
          const sanitized = sanitizePendingEnvironment(
            teamKey,
            id,
            recordValue as Partial<PendingEnvironment>
          );
          teamMap[id] = sanitized;
        } else {
          for (const [candidateKey, rawValue] of Object.entries(recordValue)) {
            if (!rawValue || typeof rawValue !== "object") {
              continue;
            }
            const rawEnv = rawValue as Partial<PendingEnvironment>;
            const envId =
              typeof rawEnv.id === "string" && rawEnv.id.length > 0
                ? rawEnv.id
                : candidateKey;
            const envTeamSlug =
              typeof rawEnv.teamSlugOrId === "string" &&
              rawEnv.teamSlugOrId.length > 0
                ? rawEnv.teamSlugOrId
                : teamKey;
            const sanitized = sanitizePendingEnvironment(
              envTeamSlug,
              envId,
              rawEnv
            );
            teamMap[envId] = sanitized;
          }
        }
      }

      if (Object.keys(teamMap).length > 0) {
        teamEntries.push([teamKey, teamMap]);
      }
    }

    return Object.fromEntries(teamEntries);
  } catch (error) {
    console.warn("Failed to parse pending environments from storage", error);
    return {};
  }
}

function persistState(): void {
  if (typeof window === "undefined") {
    return;
  }
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch (error) {
    console.warn("Failed to persist pending environments", error);
  }
}

function emit(): void {
  for (const listener of listeners) {
    listener();
  }
}

if (typeof window !== "undefined") {
  window.addEventListener("storage", (event) => {
    if (event.key !== STORAGE_KEY) {
      return;
    }
    state = readFromStorage();
    pendingListCache.clear();
    emit();
  });
}

export function updatePendingEnvironment(
  teamSlugOrId: string,
  pendingEnvironmentId: PendingEnvironmentId,
  patch: PendingEnvironmentDraft
): PendingEnvironment {
  const teamState = state[teamSlugOrId] ?? {};
  const prev = teamState[pendingEnvironmentId];
  const selectedRepos = patch.selectedRepos ?? prev?.selectedRepos ?? [];
  const sanitizedRepos = Array.from(new Set(selectedRepos));
  const next: PendingEnvironment = {
    id: pendingEnvironmentId,
    teamSlugOrId,
    step: patch.step ?? prev?.step ?? "select",
    selectedRepos: sanitizedRepos,
    snapshotId:
      patch.snapshotId ?? prev?.snapshotId ?? DEFAULT_MORPH_SNAPSHOT_ID,
    connectionLogin:
      patch.connectionLogin === undefined
        ? prev?.connectionLogin ?? null
        : patch.connectionLogin,
    repoSearch:
      patch.repoSearch === undefined
        ? prev?.repoSearch ?? null
        : patch.repoSearch,
    instanceId:
      patch.instanceId === undefined
        ? prev?.instanceId
        : patch.instanceId === ""
          ? undefined
          : patch.instanceId,
    envName:
      patch.envName === undefined ? prev?.envName : patch.envName ?? "",
    maintenanceScript:
      patch.maintenanceScript === undefined
        ? prev?.maintenanceScript
        : patch.maintenanceScript ?? "",
    devScript:
      patch.devScript === undefined
        ? prev?.devScript
        : patch.devScript ?? "",
    envVars:
      patch.envVars === undefined
        ? prev?.envVars
        : patch.envVars ?? [],
    exposedPorts:
      patch.exposedPorts === undefined
        ? prev?.exposedPorts
        : patch.exposedPorts ?? "",
    updatedAt: Date.now(),
  };

  state = {
    ...state,
    [teamSlugOrId]: { ...teamState, [pendingEnvironmentId]: next },
  };
  pendingListCache.delete(teamSlugOrId);
  persistState();
  emit();
  return next;
}

export function createPendingEnvironment(
  teamSlugOrId: string,
  draft: PendingEnvironmentDraft
): PendingEnvironment {
  const teamState = state[teamSlugOrId] ?? {};
  const id = createPendingEnvironmentId();
  const normalized: Partial<PendingEnvironment> = {
    ...draft,
    step: draft.step ?? "select",
    id,
    teamSlugOrId,
    updatedAt: Date.now(),
    envName:
      draft.envName === undefined || draft.envName === null
        ? undefined
        : draft.envName,
    maintenanceScript:
      draft.maintenanceScript === undefined || draft.maintenanceScript === null
        ? undefined
        : draft.maintenanceScript,
    devScript:
      draft.devScript === undefined || draft.devScript === null
        ? undefined
        : draft.devScript,
    envVars: draft.envVars ?? undefined,
    exposedPorts:
      draft.exposedPorts === undefined || draft.exposedPorts === null
        ? undefined
        : draft.exposedPorts,
    connectionLogin:
      draft.connectionLogin === undefined ? undefined : draft.connectionLogin,
    repoSearch:
      draft.repoSearch === undefined ? undefined : draft.repoSearch,
    instanceId:
      draft.instanceId === undefined || draft.instanceId === ""
        ? undefined
        : draft.instanceId,
  };
  const next = sanitizePendingEnvironment(teamSlugOrId, id, normalized);
  state = {
    ...state,
    [teamSlugOrId]: { ...teamState, [id]: next },
  };
  pendingListCache.delete(teamSlugOrId);
  persistState();
  emit();
  return next;
}

export function clearPendingEnvironment(
  teamSlugOrId: string,
  pendingEnvironmentId?: PendingEnvironmentId
): void {
  const teamState = state[teamSlugOrId];
  if (!teamState) {
    return;
  }

  if (pendingEnvironmentId) {
    if (!teamState[pendingEnvironmentId]) {
      return;
    }
    const { [pendingEnvironmentId]: _removed, ...restForTeam } = teamState;
    const nextTeamState = restForTeam;
    const { [teamSlugOrId]: _teamRemoved, ...rest } = state;
    if (Object.keys(nextTeamState).length === 0) {
      state = rest;
    } else {
      state = { ...rest, [teamSlugOrId]: nextTeamState };
    }
    pendingListCache.delete(teamSlugOrId);
  } else {
    const { [teamSlugOrId]: _removed, ...rest } = state;
    state = rest;
    pendingListCache.delete(teamSlugOrId);
  }
  persistState();
  emit();
}

export function getPendingEnvironment(
  teamSlugOrId: string,
  pendingEnvironmentId: PendingEnvironmentId
): PendingEnvironment | undefined {
  return state[teamSlugOrId]?.[pendingEnvironmentId];
}

export function getPendingEnvironments(
  teamSlugOrId: string
): PendingEnvironment[] {
  const cached = pendingListCache.get(teamSlugOrId);
  if (cached) {
    return cached;
  }
  const teamState = state[teamSlugOrId];
  if (!teamState) {
    return emptyPendingList;
  }
  const next = [...Object.values(teamState)].sort(
    (a, b) => b.updatedAt - a.updatedAt
  );
  pendingListCache.set(teamSlugOrId, next);
  return next;
}

function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function usePendingEnvironment(
  teamSlugOrId: string,
  pendingEnvironmentId: PendingEnvironmentId | undefined
): PendingEnvironment | undefined {
  return useSyncExternalStore(
    subscribe,
    () =>
      pendingEnvironmentId
        ? state[teamSlugOrId]?.[pendingEnvironmentId]
        : undefined,
    () => undefined
  );
}

export function usePendingEnvironments(
  teamSlugOrId: string
): PendingEnvironment[] {
  return useSyncExternalStore(
    subscribe,
    () => getPendingEnvironments(teamSlugOrId),
    () => []
  );
}

export function listPendingEnvironments(): PendingEnvironment[] {
  const flattened = Object.values(state).flatMap((teamMap) =>
    Object.values(teamMap)
  );
  return flattened.sort((a, b) => b.updatedAt - a.updatedAt);
}
