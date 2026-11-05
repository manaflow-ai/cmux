import { environmentBuildExec } from "./build-script.ts"
import { environmentBuildDigest, type EnvironmentSpec } from "./spec.ts"

/** The environment's latest snapshot that finished building. */
export interface EnvironmentSnapshotRecord {
  readonly snapshotId: string
  readonly digest: string
  /** The sandbox provider that built it; a snapshot never boots on another provider. */
  readonly provider: string
}

export type EnvironmentBootPlan =
  | { readonly kind: "snapshot"; readonly snapshotId: string; readonly digest: string }
  | { readonly kind: "cold"; readonly reason: "unbuilt" | "stale"; readonly digest: string; readonly setupExec: string }

/**
 * How a new workspace in this environment boots: from its snapshot when the snapshot matches the spec,
 * the base image and the provider; otherwise from the base image with the build script run on the new
 * machine (slower, same result), so an edit never blocks a workspace on a rebuild.
 */
export const environmentBootPlan = (spec: EnvironmentSpec, snapshot: EnvironmentSnapshotRecord | null, baseImage: string, provider: string): EnvironmentBootPlan => {
  const digest = environmentBuildDigest(spec, baseImage)
  if (snapshot && snapshot.digest === digest && snapshot.provider === provider) return { kind: "snapshot", snapshotId: snapshot.snapshotId, digest }
  return { kind: "cold", reason: snapshot ? "stale" : "unbuilt", digest, setupExec: environmentBuildExec(spec, digest) }
}
