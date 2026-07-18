import type { Id, SplitDirection } from "./common.js";

declare const uuidBrand: unique symbol;
/** A lowercase, hyphenated RFC 9562 UUID. */
export type UUID = string & { readonly [uuidBrand]: true };

export const TOPOLOGY_V8_CAPABILITIES = [
  "canonical-topology-snapshot-v1",
  "stable-entity-uuid-v1",
  "topology-resume-v1",
] as const;

export interface TopologyAuthority {
  daemon_instance_id: UUID;
  session_id: UUID;
}

export interface TopologyCursor extends TopologyAuthority { revision: number }

export type CanonicalLayout =
  | { type: "leaf"; pane: Id; pane_uuid: UUID }
  | { type: "split"; dir: SplitDirection; ratio: number; a: CanonicalLayout; b: CanonicalLayout };

export interface CanonicalTab {
  id: Id;
  uuid: UUID;
  kind: "pty" | "browser";
  name: string | null;
}

export interface CanonicalPane {
  id: Id;
  uuid: UUID;
  name: string | null;
  tabs: CanonicalTab[];
}

export interface CanonicalScreen {
  id: Id;
  uuid: UUID;
  name: string | null;
  layout: CanonicalLayout;
  panes: CanonicalPane[];
}

export interface CanonicalWorkspace {
  id: Id;
  uuid: UUID;
  name: string;
  screens: CanonicalScreen[];
}

export interface CanonicalTopology { workspaces: CanonicalWorkspace[] }

export interface TopologySnapshot extends TopologyCursor {
  topology: CanonicalTopology;
}

export interface TopologyTargets {
  workspaces: UUID[];
  screens: UUID[];
  panes: UUID[];
  surfaces: UUID[];
}

export type TopologyOperation =
  | "workspace-created" | "screen-created" | "pane-split" | "surface-attached"
  | "surface-closed" | "pane-closed" | "screen-closed" | "workspace-closed"
  | "workspace-renamed" | "screen-renamed" | "pane-renamed" | "surface-renamed"
  | "split-ratio-changed" | "panes-swapped" | "layout-applied" | "tab-moved"
  | "workspace-moved";

export interface TopologyDelta extends TopologyAuthority {
  event: "topology-delta";
  base_revision: number;
  revision: number;
  operation: TopologyOperation;
  targets: TopologyTargets;
  replacement: CanonicalTopology;
}

export type TopologyResnapshotReason =
  | "stale-daemon" | "stale-session" | "revision-ahead"
  | "history-gap" | "replay-too-large" | "slow-consumer";

export interface TopologyResnapshotRequiredResult extends TopologyAuthority {
  status: "resnapshot-required";
  current_revision?: number;
  reason: TopologyResnapshotReason;
}

export interface TopologyResnapshotRequiredEvent extends TopologyAuthority {
  event: "topology-resnapshot-required";
  current_revision?: number;
  reason: TopologyResnapshotReason;
}

export interface TopologySubscribedResult extends TopologyAuthority {
  status: "subscribed";
  from_revision: number;
  current_revision: number;
  replayed: number;
}

export type SubscribeTopologyResult = TopologySubscribedResult | TopologyResnapshotRequiredResult;
export type TopologyStreamEvent = TopologyDelta | TopologyResnapshotRequiredEvent;

export function topologyCursor(snapshot: TopologySnapshot): TopologyCursor {
  return {
    daemon_instance_id: snapshot.daemon_instance_id,
    session_id: snapshot.session_id,
    revision: snapshot.revision,
  };
}

export function parseTopologyCursor(value: unknown): TopologyCursor {
  const item = object(value, "topology cursor");
  return {
    daemon_instance_id: uuid(item.daemon_instance_id),
    session_id: uuid(item.session_id),
    revision: uint(item.revision),
  };
}

export function parseTopologySnapshot(value: unknown): TopologySnapshot {
  const item = object(value, "topology snapshot");
  return {
    daemon_instance_id: uuid(item.daemon_instance_id),
    session_id: uuid(item.session_id),
    revision: uint(item.revision),
    topology: canonicalTopology(item.topology),
  };
}

export function parseSubscribeTopologyResult(value: unknown): SubscribeTopologyResult {
  const item = object(value, "subscribe-topology result");
  const authority = {
    daemon_instance_id: uuid(item.daemon_instance_id),
    session_id: uuid(item.session_id),
  };
  if (item.status === "subscribed") {
    return {
      status: "subscribed",
      ...authority,
      from_revision: uint(item.from_revision),
      current_revision: uint(item.current_revision),
      replayed: uint(item.replayed),
    };
  }
  if (item.status === "resnapshot-required") {
    return {
      status: "resnapshot-required",
      ...authority,
      ...(item.current_revision === undefined ? {} : { current_revision: uint(item.current_revision) }),
      reason: resnapshotReason(item.reason),
    };
  }
  throw new Error(`invalid subscribe-topology status ${String(item.status)}`);
}

export function parseTopologyStreamEvent(value: unknown): TopologyStreamEvent {
  const item = object(value, "topology stream event");
  const authority = {
    daemon_instance_id: uuid(item.daemon_instance_id),
    session_id: uuid(item.session_id),
  };
  if (item.event === "topology-resnapshot-required") {
    return {
      event: "topology-resnapshot-required",
      ...authority,
      ...(item.current_revision === undefined ? {} : { current_revision: uint(item.current_revision) }),
      reason: resnapshotReason(item.reason),
    };
  }
  if (item.event !== "topology-delta") {
    throw new Error(`unexpected topology stream event ${String(item.event)}`);
  }
  return {
    event: "topology-delta",
    ...authority,
    base_revision: uint(item.base_revision),
    revision: uint(item.revision),
    operation: operation(item.operation),
    targets: targets(item.targets),
    replacement: canonicalTopology(item.replacement),
  };
}

export function validateTopologyDelta(
  cursor: TopologyCursor,
  delta: TopologyDelta,
): TopologyResnapshotRequiredEvent | null {
  let reason: TopologyResnapshotReason | null = null;
  if (delta.daemon_instance_id !== cursor.daemon_instance_id) reason = "stale-daemon";
  else if (delta.session_id !== cursor.session_id) reason = "stale-session";
  else if (delta.base_revision !== cursor.revision || delta.revision !== delta.base_revision + 1) {
    reason = "history-gap";
  }
  return reason === null ? null : {
    event: "topology-resnapshot-required",
    daemon_instance_id: delta.daemon_instance_id,
    session_id: delta.session_id,
    current_revision: delta.revision,
    reason,
  };
}

function canonicalTopology(value: unknown): CanonicalTopology {
  const item = object(value, "canonical topology");
  return { workspaces: array(item.workspaces, workspace) };
}

function workspace(value: unknown): CanonicalWorkspace {
  const item = object(value, "canonical workspace");
  return {
    id: uint(item.id), uuid: uuid(item.uuid), name: text(item.name),
    screens: array(item.screens, screen),
  };
}

function screen(value: unknown): CanonicalScreen {
  const item = object(value, "canonical screen");
  return {
    id: uint(item.id), uuid: uuid(item.uuid), name: nullableText(item.name),
    layout: layout(item.layout), panes: array(item.panes, pane),
  };
}

function layout(value: unknown): CanonicalLayout {
  const item = object(value, "canonical layout");
  if (item.type === "leaf") {
    return { type: "leaf", pane: uint(item.pane), pane_uuid: uuid(item.pane_uuid) };
  }
  if (item.type === "split" && (item.dir === "right" || item.dir === "down")) {
    return { type: "split", dir: item.dir, ratio: finite(item.ratio), a: layout(item.a), b: layout(item.b) };
  }
  throw new Error(`invalid canonical layout type ${String(item.type)}`);
}

function pane(value: unknown): CanonicalPane {
  const item = object(value, "canonical pane");
  return {
    id: uint(item.id), uuid: uuid(item.uuid), name: nullableText(item.name),
    tabs: array(item.tabs, tab),
  };
}

function tab(value: unknown): CanonicalTab {
  const item = object(value, "canonical tab");
  if (item.kind !== "pty" && item.kind !== "browser") throw new Error("invalid canonical tab kind");
  return { id: uint(item.id), uuid: uuid(item.uuid), kind: item.kind, name: nullableText(item.name) };
}

function targets(value: unknown): TopologyTargets {
  const item = object(value, "topology targets");
  return {
    workspaces: optionalArray(item.workspaces, uuid), screens: optionalArray(item.screens, uuid),
    panes: optionalArray(item.panes, uuid), surfaces: optionalArray(item.surfaces, uuid),
  };
}

function operation(value: unknown): TopologyOperation {
  const values: TopologyOperation[] = [
    "workspace-created", "screen-created", "pane-split", "surface-attached",
    "surface-closed", "pane-closed", "screen-closed", "workspace-closed",
    "workspace-renamed", "screen-renamed", "pane-renamed", "surface-renamed",
    "split-ratio-changed", "panes-swapped", "layout-applied", "tab-moved", "workspace-moved",
  ];
  if (!values.includes(value as TopologyOperation)) throw new Error(`invalid topology operation ${String(value)}`);
  return value as TopologyOperation;
}

function resnapshotReason(value: unknown): TopologyResnapshotReason {
  const values: TopologyResnapshotReason[] = [
    "stale-daemon", "stale-session", "revision-ahead", "history-gap", "replay-too-large", "slow-consumer",
  ];
  if (!values.includes(value as TopologyResnapshotReason)) throw new Error(`invalid resnapshot reason ${String(value)}`);
  return value as TopologyResnapshotReason;
}

function uuid(value: unknown): UUID {
  const textValue = text(value);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(textValue)) {
    throw new Error(`invalid lowercase UUID ${textValue}`);
  }
  return textValue as UUID;
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} is not an object`);
  return value as Record<string, unknown>;
}
function array<T>(value: unknown, parse: (item: unknown) => T): T[] {
  if (!Array.isArray(value)) throw new Error("expected array");
  return value.map(parse);
}
function optionalArray<T>(value: unknown, parse: (item: unknown) => T): T[] {
  return value === undefined ? [] : array(value, parse);
}
function uint(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new Error(`expected non-negative integer, got ${String(value)}`);
  return value as number;
}
function finite(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("expected finite number");
  return value;
}
function text(value: unknown): string {
  if (typeof value !== "string") throw new Error("expected string");
  return value;
}
function nullableText(value: unknown): string | null {
  return value === null ? null : text(value);
}
