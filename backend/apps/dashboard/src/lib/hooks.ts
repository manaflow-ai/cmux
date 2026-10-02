import { useCallback, useEffect, useRef, useState } from "react"

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

/** Subscribes to the user's stream over cmux.wire/1 while `token` is set. */
export function useWire(apiUrl: string | undefined, token: string | null, stream: string | null) {
  const [frames, setFrames] = useState<Array<WireEvent>>([])
  const [status, setStatus] = useState("idle")
  useEffect(() => {
    if (!apiUrl || !token || !stream) return
    const ws = new WebSocket(`${apiUrl.replace(/^http/, "ws")}/v1/wire/user`, ["cmux.wire.v1", `bearer.${token}`])
    setStatus("connecting")
    ws.onopen = () => {
      setStatus("open")
      ws.send(JSON.stringify({ t: "subscribe", stream, pending: [] }))
    }
    ws.onmessage = (e) => {
      const f = JSON.parse(String(e.data)) as WireEvent
      setFrames((fs) => [f, ...fs].slice(0, 50))
    }
    ws.onclose = () => setStatus("closed")
    ws.onerror = () => setStatus("error")
    return () => ws.close()
  }, [apiUrl, token, stream])
  return { frames, status }
}
