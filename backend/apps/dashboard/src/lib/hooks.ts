import { useCallback, useEffect, useRef, useState } from "react"
import { wireToken } from "./server"

/**
 * Loads data when `key` changes (and on `reload()`); the only effect in the
 * dashboard lives here. A stale response from an older key is dropped.
 */
export function useLoad<T>(key: string | null, load: () => Promise<T>) {
  const [state, setState] = useState<{ data?: T; error?: string; loading: boolean }>({ loading: key !== null })
  const [tick, setTick] = useState(0)
  const loadRef = useRef(load)
  loadRef.current = load
  useEffect(() => {
    if (key === null) return
    let live = true
    setState((s) => ({ ...s, loading: true }))
    loadRef.current().then(
      (data) => live && setState({ data, loading: false }),
      (e: unknown) => live && setState({ error: String(e), loading: false })
    )
    return () => {
      live = false
    }
  }, [key, tick])
  const reload = useCallback(() => setTick((t) => t + 1), [])
  return { ...state, reload }
}

export interface WireEvent {
  readonly t: string
  readonly seq?: number
  readonly tx?: string
  readonly op?: string
  readonly stream?: string
}

/**
 * Subscribes to the user's stream over cmux.wire/1 while `stream` is set. The
 * socket token comes from the `wireToken` server function (see its trade-off note).
 */
export function useWire(stream: string | null) {
  const [frames, setFrames] = useState<Array<WireEvent>>([])
  const [status, setStatus] = useState("idle")
  useEffect(() => {
    if (!stream) return
    let ws: WebSocket | undefined
    let live = true
    const attach = (socket: WebSocket) => {
      socket.onopen = () => {
        setStatus("open")
        socket.send(JSON.stringify({ t: "subscribe", stream, pending: [] }))
      }
      socket.onmessage = (e) => {
        const f = JSON.parse(String(e.data)) as WireEvent
        setFrames((fs) => [f, ...fs].slice(0, 50))
      }
      socket.onclose = () => setStatus("closed")
      socket.onerror = () => setStatus("error")
    }
    setStatus("connecting")
    void wireToken().then(({ token, apiUrl }) => {
      if (!live) return
      if (!token) return setStatus("signed out")
      ws = new WebSocket(`${apiUrl.replace(/^http/, "ws")}/v1/wire/user`, ["cmux.wire.v1", `bearer.${token}`])
      attach(ws)
    })
    return () => {
      live = false
      ws?.close()
    }
  }, [stream])
  return { frames, status }
}
