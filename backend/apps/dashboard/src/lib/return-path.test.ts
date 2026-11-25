import { beforeEach, expect, test } from "bun:test"
import { integrationCallbackReturnPath, saveReturnPath, takeReturnPath } from "./return-path"

const store = new Map<string, string>()
;(globalThis as Record<string, unknown>).sessionStorage = {
  getItem: (key: string) => store.get(key) ?? null,
  setItem: (key: string, value: string) => void store.set(key, value),
  removeItem: (key: string) => void store.delete(key),
}
beforeEach(() => store.clear())

test("a signed-out integration callback comes back after sign-in with only the provider's fields (Leo 2026-11-25)", () => {
  const back = integrationCallbackReturnPath({ state: "a.b-c_d", code: "1234", installation_id: "42", setup_action: "install" })
  expect(back).toBe("/integrations/callback?state=a.b-c_d&code=1234&installation_id=42&setup_action=install")
  saveReturnPath(back!)
  expect(takeReturnPath()).toBe(back!)
  expect(takeReturnPath()).toBeNull()
})

test("a callback with no state, or any other path, is never a return path", () => {
  expect(integrationCallbackReturnPath({ code: "1234" })).toBeUndefined()
  for (const path of [
    "https://evil.example/integrations/callback?state=x",
    "//evil.example/integrations/callback?state=x",
    "/integrations/callback?state=x&next=https://evil.example",
    "/integrations/callback?state=x#frag",
    "/devices",
  ]) {
    saveReturnPath(path)
    expect(takeReturnPath()).toBeNull()
  }
})

test("invite paths still come back", () => {
  const invite = "/i/d0123456789ABCDEFGHJKMNPQRS#0123456789ABCDEFGHJKMNPQRS"
  saveReturnPath(invite)
  expect(takeReturnPath()).toBe(invite)
})
