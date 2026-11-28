import { useEffect, useState } from "react";

export function useTicker(active: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    setNow(Date.now());
    const id = setInterval(() => setNow(Date.now()), 1_000);
    return () => clearInterval(id);
  }, [active]);
  return now;
}

export function useActivityStartedAt(active: boolean, key: string): number {
  const [startedAt, setStartedAt] = useState(() => Date.now());
  useEffect(() => {
    if (active) setStartedAt(Date.now());
  }, [active, key]);
  return startedAt;
}
