import { INFERENCE_PERSONAL_PLAN_IDS, INFERENCE_TEAM_PLAN_IDS } from "@cmux/protocol"
import { describe, expect, it } from "vitest"
// @ts-expect-error a Vite raw import (the test runner bundles it; the Worker build never sees it)
import wranglerText from "../wrangler.jsonc?raw"
// @ts-expect-error a Vite raw import of web billing's plan ids (the mirror inference-plans.ts names)
import webProText from "../../../../web/services/billing/pro.ts?raw"
import { cloudConfig } from "../src/cloud-driver.ts"
import { entitlementsOn } from "../src/cloud-entitlements.ts"
import { createConfigProblem, PAID_PLAN_LIMITS, teamPlan, type CloudConfig } from "../src/domains/cloud-plan.ts"
import type { Env } from "../src/env.ts"

/**
 * The production Worker (wrangler.jsonc env.production) with paid Cloud entitlements on
 * (paid-product-DESIGN.md section 9.2): a paid team gets its plan's limits, every other team gets
 * no plan (production never has the allowlist stub), and production may only turn entitlements on
 * once it can create a machine, so nobody is sold a Cloud plan that answers "not configured".
 */

/** JSONC to JSON: drops comments outside strings (wrangler.jsonc has no trailing commas). */
const stripComments = (text: string): string => {
  let out = ""
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!
    if (c === '"') {
      let j = i + 1
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1
      out += text.slice(i, j + 1)
      i = j
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++
      out += "\n"
    } else out += c
  }
  return out
}

const productionVars = (): Record<string, string> => {
  const doc = JSON.parse(stripComments(wranglerText as string)) as { env: { production: { name: string; vars: Record<string, string> } } }
  expect(doc.env.production.name).toBe("cmux-api")
  return doc.env.production.vars
}

/** A team's paid plan as CloudDO would last know it (cloud-entitlements.ts), fixed per test. */
const knownPlans = (enabled: boolean, plans: Record<string, string>): CloudConfig["entitlements"] => ({ enabled, plan: (team) => plans[team] ?? null })

/** The production config with the flag forced on (the flip), plus extra vars a test sets. */
const productionWith = (extra: Record<string, string>, plans: Record<string, string>): CloudConfig => {
  const vars = { ...productionVars(), CLOUD_PLAN_ENTITLEMENTS: "on", ...extra } as unknown as Env
  return { ...cloudConfig(vars), entitlements: knownPlans(entitlementsOn(vars), plans) }
}

/** Whether a config with these vars can create a machine (the reducer's createConfigProblem). */
const canCreate = (vars: Record<string, string>) => createConfigProblem(cloudConfig(vars as unknown as Env)) === undefined

describe("Cloud plan entitlements in the production config", () => {
  it("every paid plan id web billing writes has Cloud limits, and nothing else does", () => {
    const paid = new Set([...INFERENCE_PERSONAL_PLAN_IDS, ...INFERENCE_TEAM_PLAN_IDS])
    expect(new Set(Object.keys(PAID_PLAN_LIMITS))).toEqual(paid)
    // web/services/billing/pro.ts PAID_PLAN_IDS, by its *_PLAN_ID constants: a new web plan id needs limits here too.
    const web = webProText as string
    const ids = new Map([...web.matchAll(/export const (\w+_PLAN_ID) = "([a-z_]+)";/g)].map((m) => [m[1]!, m[2]!]))
    const list = /export const PAID_PLAN_IDS = \[([^\]]+)\]/.exec(web)?.[1]
    expect(list, "web PAID_PLAN_IDS not found").toBeDefined()
    const webPaid = new Set(list!.split(",").map((n) => n.trim()).filter(Boolean).map((n) => ids.get(n) ?? `unknown constant ${n}`))
    expect(webPaid).toEqual(paid)
  })

  it("with the flag on, each paid plan gets its limits", () => {
    const plans = Object.fromEntries(Object.keys(PAID_PLAN_LIMITS).map((id) => [`team_${id}`, id]))
    const config = productionWith({}, plans)
    expect(config.environment).toBe("production")
    for (const id of Object.keys(PAID_PLAN_LIMITS)) expect(teamPlan(config, `team_${id}`)).toEqual(PAID_PLAN_LIMITS[id])
  })

  it("an unpaid team gets no plan, even on CLOUD_ALLOWED_TEAMS (no stub plan in production)", () => {
    const config = productionWith({ CLOUD_ALLOWED_TEAMS: "team_unpaid" }, { team_paid: "pro" })
    expect(config.allowedTeams.has("team_unpaid")).toBe(true)
    expect(teamPlan(config, "team_unpaid")).toBeNull()
    expect(teamPlan(config, null)).toBeNull()
  })

  it("an unknown plan id is no plan", () => {
    expect(teamPlan(productionWith({}, { team_x: "enterprise" }), "team_x")).toBeNull()
  })

  it("with the flag off, a paid team gets no plan either", () => {
    expect(teamPlan(productionWith({ CLOUD_PLAN_ENTITLEMENTS: "off" }, { team_paid: "pro" }), "team_paid")).toBeNull()
  })

  it("the provider rule: production can create only with its own image on either transport", () => {
    const prod = { ...productionVars(), CLOUD_PLAN_ENTITLEMENTS: "on" }
    // Keys are secrets (prod-promote.ts G5 checks their names); here only their presence is assumed.
    const keys = { CLOUD_FREESTYLE_API_KEY: "secret-name-only", CLOUD_VM_API_SERVICE_KEY: "secret-name-only" }
    expect(canCreate({ ...prod, ...keys, CLOUD_VM_TRANSPORT: "direct", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-prod-vmimg-ci-1" })).toBe(true)
    expect(canCreate({ ...prod, ...keys, CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-prod-vmimg-ci-1" })).toBe(true)
    // Another environment's image, no image, no key, or the wrong name prefix: nothing to sell.
    expect(canCreate({ ...prod, ...keys, CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-ci-1" })).toBe(false)
    expect(canCreate({ ...prod, ...keys, CLOUD_FREESTYLE_SNAPSHOT: "" })).toBe(false)
    expect(canCreate({ ...prod, CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-prod-vmimg-ci-1" })).toBe(false)
    expect(canCreate({ ...prod, ...keys, CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-prod-vmimg-ci-1", CLOUD_NAME_PREFIX: "cmuxnp-stg-cld-" })).toBe(false)
    const vmApi = { CLOUD_VM_TRANSPORT: "vm-api", CLOUD_VM_API_ORIGIN: "https://vm.example", CLOUD_VM_API_IMAGE: "cloud-agent", CLOUD_VM_API_IMAGE_REVISION: "v1" }
    expect(canCreate({ ...prod, ...keys, ...vmApi })).toBe(true)
    expect(canCreate({ ...prod, ...keys, ...vmApi, CLOUD_VM_API_IMAGE: "" })).toBe(false)
    expect(canCreate({ ...prod, ...vmApi })).toBe(false)
    expect(canCreate({ ...prod, ...keys, CLOUD_VM_TRANSPORT: "vmapi", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-prod-vmimg-ci-1" })).toBe(false)
  })

  it("production turns entitlements on only with a provider it can create machines with", () => {
    const vars = productionVars()
    if (!entitlementsOn(vars)) return
    expect(canCreate({ ...vars, CLOUD_FREESTYLE_API_KEY: "secret-name-only", CLOUD_VM_API_SERVICE_KEY: "secret-name-only" }), "CLOUD_PLAN_ENTITLEMENTS is on in production, but production has no Cloud image or provider").toBe(true)
  })
})
