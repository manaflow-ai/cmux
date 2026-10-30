import { expect, test } from "bun:test"
import { INTEGRATION_RETURN_TEAM_KEY, integrationReturnPath, integrationReturnTeamKey } from "./-return"

test("OAuth return state is isolated per callback tab", () => {
  expect(integrationReturnTeamKey(undefined)).toBe(INTEGRATION_RETURN_TEAM_KEY)
  expect(integrationReturnTeamKey("abc")).toBe(`${INTEGRATION_RETURN_TEAM_KEY}:abc`)
  expect(integrationReturnTeamKey("other-state")).not.toBe(integrationReturnTeamKey("abc"))
})

test("OAuth return preserves a selected team without copying unsafe URL text", () => {
  expect(integrationReturnPath(undefined)).toBe("/integrations")
  expect(integrationReturnPath("")).toBe("/integrations")
  expect(integrationReturnPath("team_abc&next=/admin")).toBe("/integrations?team=team_abc%26next%3D%2Fadmin")
})
