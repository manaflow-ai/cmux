import type { Env } from "../env.ts"
import type { CloudProvider } from "./contract.ts"
import { freestyleCloud } from "./freestyle/cloud.ts"

/**
 * Wiring: which provider implementation backs this deployment's direct Cloud transport. Each provider
 * folder exports one of these; its settings (key, URL, boot image) are its own env names. Only
 * Freestyle exists today; a new provider adds its folder and one line here, and CloudDO, the guard
 * and the domain stay as they are.
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
