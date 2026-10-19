import { DurableObject } from "cloudflare:workers"
import type { Env } from "./env.ts"

/**
 * DO-only release (2026-10-19, HQ skills/infra/cloud-api-promote): production creates the
 * ChiefBrainDO (v15) and HandDO (v16) classes before any code uses them, so the Chief brain
 * promote that follows adds no class and can roll back to this version. Nothing binds or
 * reaches these classes here; any request answers 404.
 */
export class ChiefBrainDO extends DurableObject<Env> {
  override async fetch(): Promise<Response> {
    return new Response("not found", { status: 404 })
  }
}

export class HandDO extends DurableObject<Env> {
  override async fetch(): Promise<Response> {
    return new Response("not found", { status: 404 })
  }
}
