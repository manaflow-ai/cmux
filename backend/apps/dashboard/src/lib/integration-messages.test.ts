import { expect, test } from "bun:test"
import { CANCELLED_MESSAGE, integrationMessage, integrationMessageLine, OWNER_REQUEST_MESSAGE } from "./integration-messages"

test("a known code reads as a sentence and a step, never `code: message`", () => {
  const m = integrationMessage({ code: "integration.not_found", message: "no github connection" }, 404)
  expect(m.button).toBe("connect")
  expect(integrationMessageLine(m)).toBe("GitHub isn't connected for this team. Connect GitHub, then try again.")
  expect(integrationMessageLine(m)).not.toContain("integration.not_found")
})

test("the API's next wins over the table's step", () => {
  const m = integrationMessage({ code: "policy.denied", message: "x", next: "Ask a team admin to allow workflow file changes." })
  expect(m.next).toBe("Ask a team admin to allow workflow file changes.")
  expect(m.text).toBe("The team's policy doesn't allow this.")
})

test("an unknown code shows the API's message, never the code", () => {
  const m = integrationMessage({ code: "weird.thing", message: "the provider timed out" })
  expect(integrationMessageLine(m)).toBe("The provider timed out. Try again.")
  expect(integrationMessage(undefined).text).toBe("Something went wrong.")
  expect(integrationMessage(undefined, 401).button).toBe("sign-in")
})

test("an owner request is pending, a cancel offers to start again", () => {
  expect(OWNER_REQUEST_MESSAGE.pending).toBe(true)
  expect(CANCELLED_MESSAGE.button).toBe("connect")
})
