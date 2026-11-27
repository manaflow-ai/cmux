import { apnsPayload } from "../src/push.ts"

// Use the production serializer so the simulator gate cannot silently drift to
// a hand-written payload that the server no longer sends.
const eventId = process.argv[2]
if (!eventId || !/^[a-zA-Z0-9_-]{8,80}$/.test(eventId)) {
  throw new Error("usage: bun scripts/push-gate-payload.ts <unique-event-id (8..80 alphanumeric, _ or -)>")
}
console.log(JSON.stringify(apnsPayload({
  eventId,
  kind: "permission",
  macId: "mac-studio",
  macName: "Mac Studio",
  sessionId: "mock-t-claude",
  agent: "Claude Code",
  permissionId: `push-gate-${eventId}`,
  title: eventId,
  options: [
    { id: "once", label: "Allow once", kind: "allow_once" },
    { id: "deny", label: "Deny", kind: "reject_once" },
  ],
})))
