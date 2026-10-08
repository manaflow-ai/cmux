import { describe, expect, it } from "vitest"
import { defaultInstallClasses } from "../src/domains/user.ts"
import { readCert, setup, sshLine } from "./team-ssh-support.ts"

/**
 * cx-wb5.66: team_vm.ssh_cert has risk execute. An install token gets a (force-command restricted) agent
 * certificate only when its grant covers execute or names the cloud-link class; there is no exemption.
 */
describe("team SSH certificates for install tokens (grant gate, workerd)", () => {
  it("cli with execute, and the iPhone and Mac defaults with cloud-link, get a restricted certificate; an install with neither is refused", async () => {
    const t = await setup("stack-ssh-0000000041")
    const key = await sshLine("ed25519")
    const cases: Array<[string, Array<string>, string]> = [
      ["cli", [...defaultInstallClasses("cli")], "inst_00000000000000000041"],
      ["ios", [...defaultInstallClasses("ios")], "inst_00000000000000000042"],
      ["mac", [...defaultInstallClasses("mac")], "inst_00000000000000000043"]
    ]
    for (const [kind, classes, id] of cases) {
      const r = await t.op(t.install(t.owner, classes, kind, id), "team_vm.ssh_cert", { public_key: key })
      expect(r.ok, `${kind}: ${r.error?.code}`).toBe(true)
      expect(r.value).toMatchObject({ class: "agent", principals: ["lawrence-agents"] })
      const c = await readCert(r.value.certificate, r.value.ca_public_key)
      expect(c.verified).toBe(true)
      expect(c.critical).toEqual({ "force-command": "cmux team restricted-shell" })
      // Still never a full shell for an install token.
      expect((await t.op(t.install(t.owner, classes, kind, id), "team_vm.ssh_cert", { public_key: key, class: "human" })).error!.code).toBe("team_vm.ssh_class_refused")
    }
    // The bug: mutate-own without execute or cloud-link (an old iPhone default, a narrowed Mac grant) got an agent certificate.
    for (const kind of ["ios", "mac", "cli"]) {
      const r = await t.op(t.install(t.owner, ["read", "mutate-own"], kind, "inst_00000000000000000044"), "team_vm.ssh_cert", { public_key: key })
      expect(r.ok).toBe(false)
      expect(r.error!.code).toBe("auth.forbidden")
      expect((await t.op(t.install(t.owner, ["read", "mutate-own", "mutate-shared"], kind, "inst_00000000000000000044"), "team_vm.ssh_cert", { public_key: key })).error!.code).toBe("auth.forbidden")
    }
  })
})
