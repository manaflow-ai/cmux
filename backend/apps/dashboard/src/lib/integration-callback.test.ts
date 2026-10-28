import { expect, test } from "bun:test"
import { integrationCompletionRequest, integrationTeamHint } from "./integration-callback"

const token = (payload: unknown) =>
  `header.${btoa(JSON.stringify(payload)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}.signature`

test("routes a signed integration callback to its claimed team", () => {
  expect(integrationTeamHint(token({ team: "team_0123456789abcdef0123" }))).toBe(
    "team_0123456789abcdef0123",
  )
})

test("keeps personal-team callback completion scoped", () => {
  const state = token({ team: "team_abcdef0123456789abcd" })
  expect(integrationCompletionRequest(state, { installation_id: "42" })).toEqual({
    params: { state, installation_id: "42" },
    team: "team_abcdef0123456789abcd",
    idempotency_key: `complete:${state.slice(-40)}`,
  })
})

test("does not route malformed or untrusted callback state", () => {
  expect(integrationTeamHint(token({ team: "team_not-a-team" }))).toBeUndefined()
  expect(integrationTeamHint("not-a-jwt")).toBeUndefined()
  expect(
    integrationTeamHint(
      token({ team: "team_0123456789abcdef0123", extra: "ignored" }).replace(
        "header.",
        "header.tampered.",
      ),
    ),
  ).toBeUndefined()
})
