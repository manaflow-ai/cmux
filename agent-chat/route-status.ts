/**
 * Provider-neutral routing state for the session UI and future runtime
 * surfaces. Adapters may add an explicit health value later; older routing
 * events remain valid because health is derived from their lifecycle phase.
 */
export type RoutePhase = "started" | "rerouted" | "handoff" | "completed";
export type RouteHealth = "unknown" | "healthy" | "degraded" | "unavailable";

export interface RouteEventLike {
  readonly kind?: unknown;
  readonly phase: RoutePhase;
  readonly conversationId: string;
  readonly requestId: string;
  readonly attempt: number;
  readonly parentSessionId?: string;
  readonly parentConversationId?: string;
  readonly provider?: string;
  readonly model?: string;
  readonly reason?: string;
  readonly handoffMode?: "native_fork" | "compact_replay";
  readonly retryAfterMs?: number;
  readonly health?: RouteHealth;
  readonly at?: number;
}

export interface RouteStatus {
  readonly phase: RoutePhase;
  readonly health: RouteHealth;
  readonly conversationId: string;
  readonly requestId: string;
  readonly attempt: number;
  readonly parentSessionId?: string;
  readonly parentConversationId?: string;
  readonly provider?: string;
  readonly model?: string;
  readonly reason?: string;
  readonly handoffMode?: "native_fork" | "compact_replay";
  readonly retryAfterMs?: number;
  readonly updatedAt?: number;
}

export function routeHealthForPhase(phase: RoutePhase): RouteHealth {
  switch (phase) {
    case "completed":
      return "healthy";
    case "rerouted":
    case "handoff":
      return "degraded";
    case "started":
      return "unknown";
  }
}

export function normalizeRouteStatus(event: RouteEventLike): RouteStatus {
  const { kind: _kind, health, at, ...metadata } = event;
  return {
    ...metadata,
    health: isRouteHealth(health) ? health : routeHealthForPhase(event.phase),
    ...(at === undefined ? {} : { updatedAt: at }),
  };
}

export function latestRouteStatus(events: readonly unknown[]): RouteStatus | null {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (!event || typeof event !== "object" || (event as { kind?: unknown }).kind !== "routing") continue;
    const candidate = event as RouteEventLike;
    if (
      !isRoutePhase(candidate.phase) ||
      typeof candidate.conversationId !== "string" ||
      typeof candidate.requestId !== "string" ||
      typeof candidate.attempt !== "number" ||
      !Number.isFinite(candidate.attempt)
    ) {
      continue;
    }
    return normalizeRouteStatus(candidate);
  }
  return null;
}

function isRoutePhase(value: unknown): value is RoutePhase {
  return value === "started" || value === "rerouted" || value === "handoff" || value === "completed";
}

function isRouteHealth(value: unknown): value is RouteHealth {
  return value === "unknown" || value === "healthy" || value === "degraded" || value === "unavailable";
}
