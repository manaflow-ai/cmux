import { expect, test } from "bun:test"
import { integrationCompletionRequest, integrationConfigureLink, integrationReturnLink, integrationTeamHint } from "./integration-callback"

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


test("completion frame uses the originating team, not the dashboard search scope", () => {
  const state = token({ team: "team_0123456789abcdef0123" })
  const search = { state: "not-the-original-state", team: "team_abcdef0123456789abcd", code: "provider-code", installation_id: "123", setup_action: "install", error: "ignored" }
  expect(integrationCompletionRequest(state, search)).toEqual({
    params: { state, code: "provider-code", installation_id: "123", setup_action: "install" },
    team: "team_0123456789abcdef0123",
    idempotency_key: `complete:${state.slice(-40)}`,
  })
})

test("opens only a GitHub installation settings page", () => {
  expect(integrationConfigureLink({ configure_url: "https://github.com/organizations/acme/settings/installations/42" })).toBe("https://github.com/organizations/acme/settings/installations/42")
  expect(integrationConfigureLink({ configure_url: "https://github.com/settings/installations/42" })).toBe("https://github.com/settings/installations/42")
  for (const bad of ["https://evil.example/settings/installations/42", "https://github.com.evil.example/settings/installations/42", "https://github.com/settings/installations/42/../x", "javascript:alert(1)"]) {
    expect(integrationConfigureLink({ configure_url: bad })).toBeUndefined()
  }
})

// backend/apps/api/test/integrations.test.ts pins both patterns to the API's.
test("returns only to a cmux chat link the API answered", () => {
  expect(integrationReturnLink({ status: "active", return_to: "cmux://session/01a12408-f0a2-79a0-8c59-cb472f5bb9aa" })).toBe("cmux://session/01a12408-f0a2-79a0-8c59-cb472f5bb9aa")
  expect(integrationReturnLink({ return_to: "cmux://agent/claude/9b2f4c1e?host=build-mac" })).toBe("cmux://agent/claude/9b2f4c1e?host=build-mac")
  expect(integrationReturnLink({ return_to: "cmux-nightly://session/ses-01#turn-turn_7" })).toBe("cmux-nightly://session/ses-01#turn-turn_7")
  for (const bad of ["https://evil.example/x", "javascript:alert(1)", "//evil.example", "cmux://evil.example/session/a", "cmux://session/a#x", "cmux://session/a?next=https://evil", "cmux://auth-callback/x", `cmux://session/${"a".repeat(600)}`, 42]) {
    expect(integrationReturnLink({ return_to: bad })).toBeUndefined()
  }
  expect(integrationReturnLink({ status: "active" })).toBeUndefined()
  expect(integrationReturnLink(null)).toBeUndefined()
})
