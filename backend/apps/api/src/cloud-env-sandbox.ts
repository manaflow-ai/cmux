import type { CloudSandbox, SandboxBootOptions } from "@cmux/cloud-env"
import { shellQuote } from "@cmux/cloud-env"
import type { GuardedCloudDriver, VmTag } from "./cloud-driver.ts"

/**
 * The environments' CloudSandbox over CloudDO's guarded provider (Freestyle direct, the cmux VM API,
 * or the test fake): the one seam that swaps the provider (plans/cmux-next/cloud-environments-DESIGN.md
 * §6). A sandbox id is the machine's provider name, a snapshot id its slug: the guard checks both
 * against this environment's prefix, and every call is checked against `tag`.
 */
export class GuardedCloudSandbox implements CloudSandbox {
  constructor(
    private readonly driver: GuardedCloudDriver,
    private readonly tag: VmTag,
    readonly provider: string
  ) {}

  async boot(o: SandboxBootOptions): Promise<{ id: string }> {
    // A builder or workspace never idles out mid-build; CloudDO sets the workspace's policy after.
    await this.driver.ensure(o.name, this.tag, { idleSeconds: 0, ...(o.snapshot ? { snapshot: o.snapshot } : {}) })
    return { id: o.name }
  }

  /** Provider exec runs as root; the environment runs as the image's work user (uid 1000). */
  exec(name: string, command: string, timeoutMs: number) {
    return this.driver.execStdin(name, this.tag, asWorkUser(command), null, timeoutMs)
  }

  async snapshot(name: string, slug: string): Promise<{ id: string }> {
    await this.driver.snapshot(name, this.tag, slug)
    return { id: slug }
  }

  destroy(name: string): Promise<void> {
    return this.driver.remove(name, this.tag)
  }
}

/** `command` as the uid-1000 account with its own HOME, from a root exec. */
export const asWorkUser = (command: string): string =>
  `u="$(getent passwd 1000 | cut -d: -f1)"; exec runuser -u "$u" -- env HOME="$(getent passwd 1000 | cut -d: -f6)" bash -c ${shellQuote(command)}`
