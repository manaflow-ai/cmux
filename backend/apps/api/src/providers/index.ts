import type { Env } from "../env.ts"
import type { TeamVmDriver } from "../team-vm-driver.ts"
import type { SandboxProvider } from "../hand-providers.ts"
import { freestyleHands } from "./freestyle/hand.ts"
import { freestyleTeamVm } from "./freestyle/team-vm.ts"

/** Which provider backs team VMs (team-vm-driver.ts): the provider's key and the driver it makes from a boot snapshot. */
export interface TeamVmProviderWiring {
  readonly id: string
  keySet(env: Env): boolean
  make(env: Env, snapshot: string): TeamVmDriver
}

/** The team VM provider of this deployment. */
export const directTeamVmProvider = (_env: Env): TeamVmProviderWiring => freestyleTeamVm

/** Written hand sandbox adapters (hand-providers.ts lists them first, then the stubs). */
export const HAND_PROVIDERS: ReadonlyArray<SandboxProvider> = [freestyleHands]

/** A hand_sandbox row written before rows named their provider: they were all made by this one. */
export const LEGACY_HAND_PROVIDER = freestyleHands.id
