import type { Env } from "../env.ts"
import type { CloudProvider } from "./contract.ts"
import type { TeamVmDriver } from "../team-vm-driver.ts"
import type { SandboxProvider } from "../hand-providers.ts"
import { freestyleCloud } from "./freestyle/cloud.ts"
import { freestyleHands } from "./freestyle/hand.ts"
import { freestyleTeamVm } from "./freestyle/team-vm.ts"

/**
 * Wiring: which provider implementation backs this deployment's direct Cloud transport. Each provider
 * folder exports one of these; its settings (key, URL, boot image) are its own env names. Only
 * Freestyle exists today; a new provider adds its folder and one line here, and CloudDO, the guard
 * and the domain stay as they are. A provider hosted outside this Worker (the VM API, or a separate
 * cloud service exposing that same generated API) is not wired here: it is reached through the vm-api
 * transport (cloud-vm-api.ts, CLOUD_VM_TRANSPORT=vm-api, CLOUD_VM_API_ORIGIN), which implements this
 * same CloudProvider contract over HTTP.
 */
export interface CloudProviderWiring {
  readonly id: string
  /** The provider's credentials are set on this deployment. */
  keySet(env: Env): boolean
  /** The configured boot image (snapshot) for new machines, or undefined. */
  image(env: Env): string | undefined
  /** The raw provider; GuardedCloudDriver always wraps it. */
  make(env: Env, image: string): CloudProvider
}

/** The direct provider of this deployment. */
export const directCloudProvider = (_env: Env): CloudProviderWiring => freestyleCloud

/** The same, for team VMs (team-vm-driver.ts): the provider's key and the driver it makes from a boot snapshot. */
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
