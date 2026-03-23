const BLUE = "#4C8DFF"
const GRAY = "#8E8E93"
const ORANGE = "#FF9500"
const RED = "#FF3B30"

function clip(value, limit = 160) {
  const text = `${value ?? ""}`.replace(/\s+/g, " ").trim()
  if (!text) return ""
  if (text.length <= limit) return text
  return `${text.slice(0, limit - 3)}...`
}

function ensure(sessions, sessionID) {
  const current = sessions.get(sessionID)
  if (current) return current
  const created = { state: "idle", waiting: "", error: "", completed: false }
  sessions.set(sessionID, created)
  return created
}

function questionText(event) {
  const question = event?.properties?.questions?.[0]
  if (!question) return "Question asked"
  return clip(question.question || question.header || question.options?.[0]?.label || "Question asked")
}

function permissionText(event) {
  const permission = clip(event?.properties?.permission || "Permission")
  const patterns = Array.isArray(event?.properties?.patterns)
    ? event.properties.patterns.map((item) => clip(item, 80)).filter(Boolean)
    : []
  if (!patterns.length) return `Permission required: ${permission}`
  return clip(`Permission required: ${permission} ${patterns.join(", ")}`)
}

function legacyPermissionText(event) {
  const message = clip(event?.properties?.message)
  if (message) return message
  const permission = clip(event?.properties?.type || "Permission")
  const pattern = event?.properties?.pattern
  const patterns = Array.isArray(pattern) ? pattern.map((item) => clip(item, 80)).filter(Boolean) : [clip(pattern, 80)].filter(Boolean)
  if (!patterns.length) return `Permission required: ${permission}`
  return clip(`Permission required: ${permission} ${patterns.join(", ")}`)
}

function extractMessage(value) {
  if (!value) return ""
  if (typeof value === "string") return value
  if (typeof value.message === "string" && value.message) return value.message
  if (value.data) return extractMessage(value.data)
  return ""
}

function errorText(event) {
  return clip(extractMessage(event?.properties?.error) || "Session error")
}

function desiredStatus(sessions) {
  const items = [...sessions.values()]
  if (!items.length) return null
  if (items.some((item) => item.error)) {
    return { value: "Error", icon: "exclamationmark.triangle.fill", color: RED, attention: true }
  }
  if (items.some((item) => item.waiting)) {
    return { value: "Needs input", icon: "bell.fill", color: BLUE, attention: true }
  }
  if (items.some((item) => item.state === "retry")) {
    return { value: "Retrying", icon: "arrow.triangle.2.circlepath", color: ORANGE, attention: false }
  }
  if (items.some((item) => item.state === "busy")) {
    return { value: "Running", icon: "bolt.fill", color: BLUE, attention: false }
  }
  // Completion: show Idle with attention (blue ring) instead of a sixth state
  if (items.some((item) => item.completed)) {
    return { value: "Idle", icon: "pause.circle.fill", color: BLUE, attention: true }
  }
  return { value: "Idle", icon: "pause.circle.fill", color: GRAY, attention: false }
}

export const CmuxIntegrationPlugin = async ({ $ }) => {
  const sessions = new Map()
  let applied = ""
  let attention = false
  async function notify(subtitle, body) {
    const text = clip(body)
    if (!text) return
    try {
      await $`cmux notify --title OpenCode --subtitle ${subtitle} --body ${text}`.quiet()
      attention = true
    } catch {}
  }

  // NOTE: clear-notifications is workspace-global; cmux does not yet support
  // --pid scoping for clears. In practice each surface runs one OpenCode instance.
  async function clearNotifications() {
    if (!attention) return
    try {
      await $`cmux clear-notifications`.quiet()
      attention = false
    } catch {}
  }

  async function setStatus(value, icon, color) {
    const pid = typeof process.pid === "number" && process.pid > 0 ? process.pid : 0
    const next = `${value}\u0000${icon}\u0000${color}\u0000${pid}`
    if (applied === next) return
    try {
      if (pid > 0) {
        await $`cmux set-status opencode ${value} --icon ${icon} --color ${color} --pid ${pid}`.quiet()
      } else {
        await $`cmux set-status opencode ${value} --icon ${icon} --color ${color}`.quiet()
      }
      applied = next
    } catch {}
  }

  // NOTE: clear-status is keyed by "opencode" but not scoped by --pid.
  // Same limitation as clearNotifications above.
  async function clearStatus() {
    if (!applied) return
    try {
      await $`cmux clear-status opencode`.quiet()
      applied = ""
    } catch {}
  }

  async function sync() {
    const next = desiredStatus(sessions)
    if (!next) {
      await clearNotifications()
      await clearStatus()
      return
    }
    if (!next.attention) {
      await clearNotifications()
    }
    await setStatus(next.value, next.icon, next.color)
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.created" || event.type === "session.updated") {
        const sessionID = event.properties?.info?.id
        if (sessionID) ensure(sessions, sessionID)
        await sync()
        return
      }

      if (event.type === "session.deleted") {
        const sessionID = event.properties?.info?.id
        if (sessionID) sessions.delete(sessionID)
        await sync()
        return
      }

      if (event.type === "session.status") {
        const sessionID = event.properties?.sessionID
        if (!sessionID) return
        const state = ensure(sessions, sessionID)
        const prevState = state.state
        state.state = event.properties?.status?.type || "idle"
        state.error = ""
        // Reset completed flag and waiting text when leaving idle (starting new work)
        if (prevState === "idle" && state.state !== "idle") {
          state.completed = false
          state.waiting = ""
        }
        // Detect completion: busy -> idle transition (not initial idle)
        if (prevState === "busy" && state.state === "idle") {
          state.completed = true
          await notify("Done", "Session completed")
        }
        await sync()
        return
      }

      if (event.type === "session.idle") {
        const sessionID = event.properties?.sessionID
        if (!sessionID) return
        const state = ensure(sessions, sessionID)
        state.state = "idle"
        state.error = ""
        await sync()
        return
      }

      if (event.type === "permission.asked") {
        const sessionID = event.properties?.sessionID
        if (!sessionID) return
        const state = ensure(sessions, sessionID)
        const text = permissionText(event)
        const changed = state.waiting !== text
        state.state = "idle"
        state.waiting = text
        state.error = ""
        if (changed) {
          await notify("Permission", text)
        }
        await sync()
        return
      }

      if (event.type === "permission.updated") {
        const sessionID = event.properties?.sessionID
        if (!sessionID) return
        const state = ensure(sessions, sessionID)
        const text = legacyPermissionText(event)
        const changed = state.waiting !== text
        state.state = "idle"
        state.waiting = text
        state.error = ""
        if (changed) {
          await notify("Permission", text)
        }
        await sync()
        return
      }

      if (event.type === "permission.replied") {
        const sessionID = event.properties?.sessionID
        const state = sessionID ? sessions.get(sessionID) : undefined
        if (!state) return
        state.waiting = ""
        await sync()
        return
      }

      if (event.type === "question.asked") {
        const sessionID = event.properties?.sessionID
        if (!sessionID) return
        const state = ensure(sessions, sessionID)
        const text = questionText(event)
        const changed = state.waiting !== text
        state.state = "idle"
        state.waiting = text
        state.error = ""
        if (changed) {
          await notify("Question", text)
        }
        await sync()
        return
      }

      if (event.type === "question.replied" || event.type === "question.rejected") {
        const sessionID = event.properties?.sessionID
        const state = sessionID ? sessions.get(sessionID) : undefined
        if (!state) return
        state.waiting = ""
        await sync()
        return
      }

      if (event.type === "session.error") {
        const text = errorText(event)
        const sessionID = event.properties?.sessionID
        if (!sessionID) {
          await notify("Error", text)
          await setStatus("Error", "exclamationmark.triangle.fill", RED)
          return
        }
        const state = ensure(sessions, sessionID)
        const changed = state.error !== text
        state.state = "idle"
        state.waiting = ""
        state.error = text
        if (changed) {
          await notify("Error", text)
        }
        await sync()
      }
    },
  }
}

export default CmuxIntegrationPlugin
